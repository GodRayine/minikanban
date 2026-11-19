import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minikanban/core/hlc.dart';
import 'package:minikanban/core/ids.dart';
import 'package:minikanban/core/platform_role.dart';
import 'package:minikanban/data/board_repository_impl.dart';
import 'package:minikanban/data/card_dao.dart';
import 'package:minikanban/data/db.dart';
import 'package:minikanban/data/device_dao.dart';
import 'package:minikanban/data/meta_dao.dart';
import 'package:minikanban/data/outbox_dao.dart';
import 'package:minikanban/domain/board_repository.dart';
import 'package:minikanban/domain/card.dart';
import 'package:minikanban/sync/protocol/dto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Детерминированные часы: каждое обращение — следующая миллисекунда.
int Function() fakeNow([int start = 1700000000000]) {
  var t = start;
  return () => t++;
}

Future<Database> openMemory() => openAppDatabase(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );

List<String> titles(BoardSnapshot board, BoardColumn column) =>
    [for (final c in board.cards(column)) c.title];

void main() {
  sqfliteFfiInit();

  late Database db;

  setUp(() async => db = await openMemory());
  tearDown(() => db.close());

  Future<BoardRepositoryImpl> openRepo(PlatformRole role) =>
      BoardRepositoryImpl.open(db, role: role, now: fakeNow());

  group('db', () {
    test('создаёт схему и выставляет user_version', () async {
      expect(await db.getVersion(), schemaVersion);
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      );
      expect(
        tables.map((r) => r['name']),
        containsAll(
          ['cards', 'outbox', 'applied_changes', 'devices', 'meta'],
        ),
      );
    });

    test('отказывается открывать БД более новой версии', () async {
      final dir = await Directory.systemTemp.createTemp('minikanban_ver_');
      addTearDown(() => dir.delete(recursive: true));
      final path = p.join(dir.path, 'future.db');

      final first = await openAppDatabase(
        path: path,
        factory: databaseFactoryFfi,
      );
      await first.setVersion(schemaVersion + 1);
      await first.close();

      await expectLater(
        openAppDatabase(path: path, factory: databaseFactoryFfi),
        throwsStateError,
      );
    });
  });

  group('MetaDao', () {
    test('device_id создаётся один раз', () async {
      final meta = MetaDao(db);
      final id = await meta.ensureDeviceId();
      expect(isUuid(id), isTrue);
      expect(await meta.ensureDeviceId(), id);
    });

    test('hlc_last и счётчик seq сохраняются', () async {
      final meta = MetaDao(db);
      expect(await meta.hlcLast(), isNull);
      const stamp = Hlc(1700000000000, 3, 'node');
      await meta.setHlcLast(stamp);
      expect(await meta.hlcLast(), stamp);

      expect(await meta.nextServerSeq(), 1);
      expect(await meta.nextServerSeq(), 2);
      expect(await meta.seqCounter(), 2);
    });
  });

  group('DeviceDao', () {
    test('upsert, список и отзыв', () async {
      final dao = DeviceDao(db);
      await dao.upsert(
        const PairedDevice(
          deviceId: 'd1',
          name: 'Pixel',
          platform: 'android',
          tokenHash: 'hash',
          pairedAt: 10,
        ),
      );
      await dao.touchLastSync('d1', 20);
      await dao.revoke('d1');

      final device = (await dao.all()).single;
      expect(device.name, 'Pixel');
      expect(device.lastSyncAt, 20);
      expect(device.revoked, isTrue);
    });
  });

  group('клиент', () {
    late BoardRepositoryImpl repo;

    setUp(() async => repo = await openRepo(PlatformRole.client));
    tearDown(() => repo.dispose());

    test('создание: карточки встают в конец колонки', () async {
      final a = await repo.create(title: '  Первая  ');
      final b = await repo.create(title: 'Вторая', description: 'текст');
      await repo.create(title: 'В работе', column: BoardColumn.doing);

      expect(a.title, 'Первая');
      expect(isUuid(a.id), isTrue);
      expect(a.pos.compareTo(b.pos), lessThan(0));
      expect(a.hlcTitle.nodeId, repo.deviceId);
      expect(a.serverSeq, 0);

      final board = await repo.loadBoard();
      expect(titles(board, BoardColumn.todo), ['Первая', 'Вторая']);
      expect(titles(board, BoardColumn.doing), ['В работе']);
      expect(board.cards(BoardColumn.todo)[1].description, 'текст');
    });

    test('некорректный заголовок не создаёт ни карточку, ни запись outbox',
        () async {
      await expectLater(
        repo.create(title: '   '),
        throwsA(isA<CardValidationException>()),
      );
      expect(await CardDao(db).count(), 0);
      expect(await OutboxDao(db).count(), 0);
    });

    test('правка меняет только затронутые поля и их метки', () async {
      final card = await repo.create(title: 'Старое', description: 'д');
      final edited = await repo.update(card.id, title: 'Новое');

      expect(edited.title, 'Новое');
      expect(edited.description, 'д');
      expect(edited.hlcTitle > card.hlcTitle, isTrue);
      expect(edited.hlcDescription, card.hlcDescription);
      expect(await repo.getCard(card.id), edited);
    });

    test('правка без изменений ничего не пишет', () async {
      final card = await repo.create(title: 'Задача');
      final same = await repo.update(card.id, title: 'Задача');
      expect(same, card);
      expect(await OutboxDao(db).count(), 1);
    });

    test('неизвестная карточка — StateError', () async {
      await expectLater(repo.update('нет', title: 'x'), throwsStateError);
      await expectLater(repo.delete('нет'), throwsStateError);
    });

    test('перенос между колонками и внутри колонки', () async {
      final a = await repo.create(title: 'A');
      final b = await repo.create(title: 'B');
      final c = await repo.create(title: 'C');

      // В другую колонку, в конец.
      await repo.move(a.id, column: BoardColumn.doing);
      var board = await repo.loadBoard();
      expect(titles(board, BoardColumn.todo), ['B', 'C']);
      expect(titles(board, BoardColumn.doing), ['A']);

      // Перед указанной карточкой.
      await repo.move(c.id, column: BoardColumn.doing, beforeId: a.id);
      // После указанной карточки (между C и A).
      await repo.move(b.id, column: BoardColumn.doing, afterId: c.id);
      board = await repo.loadBoard();
      expect(titles(board, BoardColumn.todo), isEmpty);
      expect(titles(board, BoardColumn.doing), ['C', 'B', 'A']);

      // Внутри колонки: A в начало.
      await repo.move(a.id, column: BoardColumn.doing, beforeId: c.id);
      board = await repo.loadBoard();
      expect(titles(board, BoardColumn.doing), ['A', 'C', 'B']);
    });

    test('перенос на то же место — без изменений', () async {
      final a = await repo.create(title: 'A');
      final b = await repo.create(title: 'B');
      final before = await OutboxDao(db).count();

      expect(await repo.move(b.id, column: BoardColumn.todo), b);
      expect(
        await repo.move(b.id, column: BoardColumn.todo, afterId: a.id),
        b,
      );
      expect(
        await repo.move(a.id, column: BoardColumn.todo, beforeId: b.id),
        a,
      );
      expect(await OutboxDao(db).count(), before);
    });

    test('удаление — tombstone, restore возвращает на прежнее место', () async {
      await repo.create(title: 'A');
      final b = await repo.create(title: 'B');
      await repo.create(title: 'C');

      await repo.delete(b.id);
      expect(titles(await repo.loadBoard(), BoardColumn.todo), ['A', 'C']);
      final tombstone = await repo.getCard(b.id);
      expect(tombstone!.deleted, isTrue);
      expect(await CardDao(db).count(), 3);

      final restored = await repo.restore(b.id);
      expect(restored.deleted, isFalse);
      expect(restored.hlcDeleted > tombstone.hlcDeleted, isTrue);
      expect(
        titles(await repo.loadBoard(), BoardColumn.todo),
        ['A', 'B', 'C'],
      );
    });

    test('каждая правка пополняет outbox нужными полями', () async {
      final outbox = OutboxDao(db);
      final card = await repo.create(title: 'Задача', description: 'д');
      await repo.update(card.id, title: 'Задача 2');
      await repo.move(card.id, column: BoardColumn.done);
      await repo.delete(card.id);
      await repo.restore(card.id);

      final pending = await outbox.pending();
      expect(pending, hasLength(5));
      expect(pending.map((c) => c.id).toSet(), {card.id});
      expect(pending.map((c) => c.changeId).toSet(), hasLength(5));

      expect(
        pending[0].fields.keys,
        containsAll(['title', 'description', 'column', 'pos', 'deleted']),
      );
      expect(pending[0].createdAt, card.createdAt);
      expect(pending[1].hlc.keys, ['title']);
      expect(pending[1].fields['title'], 'Задача 2');
      // Ключ порядка в пустой колонке совпал с прежним — меняется только
      // колонка.
      expect(pending[2].hlc.keys, ['column']);
      expect(pending[2].fields['column'], BoardColumn.done.code);
      expect(pending[3].fields['deleted'], isTrue);
      expect(pending[4].fields['deleted'], isFalse);

      await outbox.remove(pending.take(3).map((c) => c.changeId));
      expect(await outbox.count(), 2);
    });

    test('server_seq на клиенте не назначается', () async {
      final card = await repo.create(title: 'Задача');
      await repo.update(card.id, title: 'Другая');
      expect((await repo.getCard(card.id))!.serverSeq, 0);
      expect(await MetaDao(db).seqCounter(), 0);
    });

    test('поток доски: текущее состояние и обновление после записей', () async {
      await repo.create(title: 'A');
      final seen = <List<String>>[];
      final sub = repo
          .watchBoard()
          .listen((board) => seen.add(titles(board, BoardColumn.todo)));
      addTearDown(sub.cancel);
      await pumpEventQueue();
      expect(seen, [
        ['A'],
      ]);

      final b = await repo.create(title: 'B');
      await repo.delete(b.id);
      await pumpEventQueue();
      expect(seen, [
        ['A'],
        ['A', 'B'],
        ['A'],
      ]);

      // Новый подписчик сразу получает актуальный снимок.
      final first = await repo.watchBoard().first;
      expect(titles(first, BoardColumn.todo), ['A']);
    });

    test('метки растут, а hlc_last сохраняется в meta', () async {
      final a = await repo.create(title: 'A');
      final b = await repo.create(title: 'B');
      expect(b.hlcTitle > a.hlcTitle, isTrue);
      expect(await MetaDao(db).hlcLast(), b.hlcTitle);
    });
  });

  group('хаб', () {
    late BoardRepositoryImpl repo;

    setUp(() async => repo = await openRepo(PlatformRole.hub));
    tearDown(() => repo.dispose());

    test('server_seq растёт с каждой правкой, outbox не используется',
        () async {
      final a = await repo.create(title: 'A');
      final b = await repo.create(title: 'B');
      expect(a.serverSeq, 1);
      expect(b.serverSeq, 2);

      final moved = await repo.move(a.id, column: BoardColumn.doing);
      expect(moved.serverSeq, 3);
      await repo.delete(b.id);
      expect((await repo.getCard(b.id))!.serverSeq, 4);
      final restored = await repo.restore(b.id);
      expect(restored.serverSeq, 5);

      expect(await MetaDao(db).seqCounter(), 5);
      expect(await OutboxDao(db).count(), 0);

      final changed = await CardDao(db).changedSince(3);
      expect(changed.map((c) => c.id), [b.id]);
    });

    test('applyRemote назначает server_seq и запоминает change_id', () async {
      final remote = phoneCreate('c1', 'С телефона');
      final result = await repo.applyRemote([remote]);
      expect(result.accepted, [remote.changeId]);
      expect(result.changedCards, 1);

      final card = (await repo.getCard('c1'))!;
      expect(card.title, 'С телефона');
      expect(card.serverSeq, 1);
      expect(await AppliedChangesDao(db).contains(remote.changeId), isTrue);

      // Повтор подтверждается, но ничего не меняет.
      final again = await repo.applyRemote([remote]);
      expect(again.accepted, [remote.changeId]);
      expect(again.changedCards, 0);
      expect(await repo.getCard('c1'), card);
      expect(await MetaDao(db).seqCounter(), 1);
      expect(await AppliedChangesDao(db).count(), 1);
    });

    test('локальная правка после applyRemote новее удалённой метки', () async {
      final remote = phoneCreate('c1', 'С телефона', millis: 1700000030000);
      await repo.applyRemote([remote]);
      final edited = await repo.update('c1', title: 'С компьютера');
      expect(edited.hlcTitle > remote.hlc['title']!, isTrue);
    });
  });

  group('applyRemote на клиенте', () {
    late BoardRepositoryImpl repo;

    setUp(() async => repo = await openRepo(PlatformRole.client));
    tearDown(() => repo.dispose());

    test('идемпотентен и не трогает outbox', () async {
      final create = phoneCreate('c1', 'Удалённая');
      final rename = CardChange(
        changeId: 'ch-rename',
        id: 'c1',
        fields: const {'title': 'Переименована', 'column': 1},
        hlc: const {
          'title': Hlc(1700000020000, 0, 'pc'),
          'column': Hlc(1700000020000, 0, 'pc'),
        },
      );

      final first = await repo.applyRemote([create, rename]);
      expect(first.changedCards, 2);
      final card = (await repo.getCard('c1'))!;
      expect(card.title, 'Переименована');
      expect(card.column, BoardColumn.doing);
      expect(card.createdAt, 1700000010000);

      // Повтор и обратный порядок дают то же состояние.
      final second = await repo.applyRemote([rename, create]);
      expect(second.changedCards, 0);
      expect(second.accepted, ['ch-rename', 'ch-create-c1']);
      expect(await repo.getCard('c1'), card);

      expect(await OutboxDao(db).count(), 0);
      expect(await AppliedChangesDao(db).count(), 0);
      expect(card.serverSeq, 0);
    });

    test('LWW по полям: старая удалённая правка не затирает новую локальную',
        () async {
      final local = await repo.create(title: 'Локальная');
      final stale = CardChange(
        changeId: 'ch-old',
        id: local.id,
        fields: const {'title': 'Устаревшая', 'column': 2},
        hlc: {
          'title': const Hlc(1600000000000, 0, 'pc'),
          // Колонку на ПК поменяли позже, чем создали карточку на телефоне.
          'column': Hlc(local.hlcColumn.millis + 5, 0, 'pc'),
        },
      );
      await repo.applyRemote([stale]);

      final merged = (await repo.getCard(local.id))!;
      expect(merged.title, 'Локальная');
      expect(merged.column, BoardColumn.done);
    });

    test('обновляет поток доски', () async {
      final seen = <int>[];
      final sub = repo.watchBoard().listen((b) => seen.add(b.length));
      addTearDown(sub.cancel);
      await pumpEventQueue();

      await repo.applyRemote([phoneCreate('c1', 'Удалённая')]);
      await pumpEventQueue();
      expect(seen, [0, 1]);
    });

    test('некорректное изменение откатывает весь пакет', () async {
      final bad = CardChange(
        changeId: 'ch-bad',
        id: 'c2',
        fields: const {'column': 7},
        hlc: const {'column': Hlc(1700000010000, 0, 'pc')},
      );
      await expectLater(
        repo.applyRemote([phoneCreate('c1', 'Хорошая'), bad]),
        throwsA(isA<ProtocolException>()),
      );
      expect(await CardDao(db).count(), 0);
    });
  });

  test('данные переживают повторное открытие файла БД', () async {
    final dir = await Directory.systemTemp.createTemp('minikanban_test_');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, databaseFileName);
    final now = fakeNow();

    var file = await openAppDatabase(path: path, factory: databaseFactoryFfi);
    var repo = await BoardRepositoryImpl.open(
      file,
      role: PlatformRole.client,
      now: now,
    );
    final deviceId = repo.deviceId;
    final a = await repo.create(title: 'A');
    final b = await repo.create(title: 'B', description: 'описание');
    await repo.move(b.id, column: BoardColumn.done);
    await repo.delete(a.id);
    final lastStamp = (await repo.getCard(a.id))!.hlcDeleted;
    await repo.dispose();
    await file.close();

    file = await openAppDatabase(path: path, factory: databaseFactoryFfi);
    addTearDown(() => file.close());
    expect(await file.getVersion(), schemaVersion);
    // Часы «перевели назад»: метки всё равно должны расти.
    repo = await BoardRepositoryImpl.open(
      file,
      role: PlatformRole.client,
      now: () => 1000,
    );
    addTearDown(repo.dispose);

    expect(repo.deviceId, deviceId);
    final board = await repo.loadBoard();
    expect(board.length, 1);
    final restoredB = board.cards(BoardColumn.done).single;
    expect(restoredB.title, 'B');
    expect(restoredB.description, 'описание');
    expect((await repo.getCard(a.id))!.deleted, isTrue);
    expect(await OutboxDao(file).count(), 4);

    final c = await repo.create(title: 'C');
    expect(c.hlcTitle > lastStamp, isTrue);
  });
}

/// Полное изменение «создана карточка» с другого устройства.
CardChange phoneCreate(String id, String title, {int millis = 1700000010000}) {
  final stamp = Hlc(millis, 0, 'pc');
  return CardChange(
    changeId: 'ch-create-$id',
    id: id,
    fields: {
      'title': title,
      'description': '',
      'column': 0,
      'pos': 'a0',
      'deleted': false,
      createdAtKey: millis,
    },
    hlc: {
      for (final f in CardField.values) f.wire: stamp,
    },
  );
}

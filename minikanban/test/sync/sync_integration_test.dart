// Интеграционные тесты: настоящий HTTPS-сервер ПК на localhost и клиент
// телефона в одном процессе, у каждого своя in-memory БД.
//
// Привязка TestWidgetsFlutterBinding здесь намеренно не используется:
// она подменяет HttpClient заглушкой.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minikanban/core/platform_role.dart';
import 'package:minikanban/data/board_repository_impl.dart';
import 'package:minikanban/data/card_dao.dart';
import 'package:minikanban/data/db.dart';
import 'package:minikanban/data/device_dao.dart';
import 'package:minikanban/data/meta_dao.dart';
import 'package:minikanban/data/outbox_dao.dart';
import 'package:minikanban/domain/board_repository.dart';
import 'package:minikanban/domain/card.dart';
import 'package:minikanban/sync/client/client_store.dart';
import 'package:minikanban/sync/client/pairing_client.dart';
import 'package:minikanban/sync/client/sync_api.dart';
import 'package:minikanban/sync/client/sync_client.dart';
import 'package:minikanban/sync/crypto_util.dart';
import 'package:minikanban/sync/protocol/dto.dart';
import 'package:minikanban/sync/protocol/merge.dart';
import 'package:minikanban/sync/protocol/qr_payload.dart';
import 'package:minikanban/sync/server/cert_service.dart';
import 'package:minikanban/sync/server/pairing_service.dart';
import 'package:minikanban/sync/server/sync_server.dart';
import 'package:minikanban/sync/sync_status.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> openMemory() => openAppDatabase(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );

/// Управляемые часы.
class TestClock {
  DateTime value = DateTime.now();

  DateTime call() => value;

  int millis() => value.millisecondsSinceEpoch;

  void advance(Duration by) => value = value.add(by);
}

/// ПК: БД, репозиторий-хаб и работающий сервер.
class Hub {
  Hub._(this.db, this.repo, this.server, this.clock);

  static Future<Hub> start(
    ServerIdentity identity, {
    int maxAttemptsPerMinute = 5,
  }) async {
    final clock = TestClock();
    final db = await openMemory();
    final repo = await BoardRepositoryImpl.open(
      db,
      role: PlatformRole.hub,
      now: clock.millis,
    );
    final server = SyncServer(
      db: db,
      repository: repo,
      identity: identity,
      serverName: 'TEST-PC',
      now: clock.call,
      pairing: PairingService(
        db,
        now: clock.call,
        maxAttemptsPerMinute: maxAttemptsPerMinute,
      ),
    );
    await server.start(
      port: 0,
      address: InternetAddress.loopbackIPv4,
      fallbackToAnyPort: false,
    );
    return Hub._(db, repo, server, clock);
  }

  final Database db;
  final BoardRepositoryImpl repo;
  final SyncServer server;
  final TestClock clock;

  Endpoint get endpoint => Endpoint('127.0.0.1', server.port);

  /// Содержимое свежего QR-кода.
  PairingQrPayload qr() {
    final code = server.pairing.newCode();
    return PairingQrPayload(
      serverId: server.serverId,
      serverName: server.serverName,
      host: 'test-pc',
      ips: const ['127.0.0.1'],
      port: server.port,
      code: code.code,
      fingerprint: server.identity.fingerprint,
      exp: code.exp,
    );
  }

  Future<List<KanbanCard>> allCards() => CardDao(db).all();

  Future<void> close() async {
    await server.dispose();
    await repo.dispose();
    await db.close();
  }
}

/// Телефон: БД, репозиторий-клиент, клиент синхронизации и привязки.
class Phone {
  Phone._(this.db, this.repo, this.store, this.client, this.pairing);

  static Future<Phone> create({String name = 'Pixel Test'}) async {
    final db = await openMemory();
    final repo = await BoardRepositoryImpl.open(db, role: PlatformRole.client);
    final store = ClientStore(db, MemoryTokenStore());
    return Phone._(
      db,
      repo,
      store,
      SyncClient(db: db, repository: repo, store: store),
      PairingClient(
        db: db,
        repository: repo,
        store: store,
        deviceName: () async => name,
      ),
    );
  }

  final Database db;
  final BoardRepositoryImpl repo;
  final ClientStore store;
  final SyncClient client;
  final PairingClient pairing;

  Future<List<KanbanCard>> allCards() => CardDao(db).all();

  Future<int> outboxCount() => OutboxDao(db).count();

  Future<void> close() async {
    client.dispose();
    await repo.dispose();
    await db.close();
  }
}

/// Значимое содержимое карточек (без `server_seq`, который есть только
/// на хабе) — для сравнения состояний двух устройств.
Map<String, Object?> contentOf(Iterable<KanbanCard> cards) => {
      for (final c in cards)
        c.id: [
          c.title,
          c.description,
          c.column,
          c.pos,
          c.deleted,
          c.createdAt,
          '${c.hlcTitle}',
          '${c.hlcDescription}',
          '${c.hlcColumn}',
          '${c.hlcPos}',
          '${c.hlcDeleted}',
        ],
    };

Future<void> expectConverged(Hub hub, Phone phone) async {
  expect(contentOf(await phone.allCards()), contentOf(await hub.allCards()));
}

Matcher throwsPairing(PairingError error) => throwsA(
      isA<PairingException>().having((e) => e.error, 'error', error),
    );

void main() {
  sqfliteFfiInit();

  late ServerIdentity identity;
  late Hub hub;
  late Phone phone;

  setUpAll(() => identity = CertService.generate());

  setUp(() async {
    hub = await Hub.start(identity);
    phone = await Phone.create();
  });

  tearDown(() async {
    await phone.close();
    await hub.close();
  });

  Future<void> pair([Phone? target]) async {
    await (target ?? phone).pairing.pairWithPayload(hub.qr());
  }

  group('сертификат', () {
    test('отпечаток — 43 символа base64url и подходит для QR', () {
      expect(identity.fingerprint, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(() => hub.qr().validate(), returnsNormally);
    });

    test('сертификат сохраняется и переиспользуется', () async {
      final dir = await Directory.systemTemp.createTemp('minikanban_cert_');
      addTearDown(() => dir.delete(recursive: true));
      final first = await CertService(dir).loadOrCreate();
      final second = await CertService(dir).loadOrCreate();
      expect(second.fingerprint, first.fingerprint);
      expect(second.certificatePem, first.certificatePem);
      expect(first.fingerprint, isNot(identity.fingerprint));
    });

    test('hello доступен без авторизации', () async {
      final api = HttpSyncApi(fingerprint: identity.fingerprint);
      addTearDown(api.close);
      final hello = await api.hello(
        hub.endpoint,
        timeout: const Duration(seconds: 5),
      );
      expect(hello.serverId, hub.server.serverId);
      expect(hello.serverName, 'TEST-PC');
      expect(hello.proto, protocolVersion);
      expect(api.seenFingerprint(hub.endpoint), identity.fingerprint);
    });

    test('неверный отпечаток — соединение отклоняется', () async {
      final other = CertService.generate();
      final api = HttpSyncApi(fingerprint: other.fingerprint);
      addTearDown(api.close);
      await expectLater(
        api.hello(hub.endpoint, timeout: const Duration(seconds: 5)),
        throwsA(isA<SyncCertException>()),
      );
    });

    test('клиент с чужим отпечатком: статус «ошибка сертификата»', () async {
      await pair();
      final link = (await phone.store.link())!;
      await phone.store.saveLink(
        ServerLink(
          serverId: link.serverId,
          serverName: link.serverName,
          host: '',
          ips: link.ips,
          port: link.port,
          fingerprint: CertService.generate().fingerprint,
          lastGood: link.lastGood,
        ),
        token: (await phone.store.token())!,
      );
      await phone.repo.create(title: 'Секрет');

      expect(await phone.client.sync(), SyncResult.certError);
      expect(phone.client.status.value.phase, SyncPhase.certError);
      expect(await hub.allCards(), isEmpty);
      expect(await phone.outboxCount(), 1);
    });
  });

  group('привязка', () {
    test('успех: токен у телефона, на ПК — только его хэш', () async {
      await pair();

      final token = await phone.store.token();
      expect(token, isNotNull);
      expect(token!.length, 43);
      final link = (await phone.store.link())!;
      expect(link.serverId, hub.server.serverId);
      expect(link.serverName, 'TEST-PC');
      expect(link.fingerprint, identity.fingerprint);
      expect(link.lastGood, hub.endpoint);

      final devices = await hub.server.devices();
      expect(devices, hasLength(1));
      expect(devices.single.deviceId, phone.repo.deviceId);
      expect(devices.single.name, 'Pixel Test');
      expect(devices.single.platform, 'android');
      expect(devices.single.tokenHash, sha256Hex(token));
      expect(devices.single.tokenHash, isNot(contains(token)));
      expect(devices.single.lastSyncAt, isNull);
    });

    test('повторное использование кода отклоняется', () async {
      final qr = hub.qr();
      await phone.pairing.pairWithPayload(qr);

      final second = await Phone.create(name: 'Второй');
      addTearDown(second.close);
      await expectLater(
        second.pairing.pairWithPayload(qr),
        throwsPairing(PairingError.codeRejected),
      );
      expect(await second.store.token(), isNull);
      expect(await hub.server.devices(), hasLength(1));
    });

    test('неверный код отклоняется', () async {
      final qr = hub.qr();
      final forged = PairingQrPayload(
        serverId: qr.serverId,
        serverName: qr.serverName,
        host: qr.host,
        ips: qr.ips,
        port: qr.port,
        code: randomSecret(16),
        fingerprint: qr.fingerprint,
        exp: qr.exp,
      );
      await expectLater(
        phone.pairing.pairWithPayload(forged),
        throwsPairing(PairingError.codeRejected),
      );
      expect(await hub.server.devices(), isEmpty);
    });

    test('истёкший код отклоняется сервером', () async {
      final qr = hub.qr();
      // На ПК прошло больше пяти минут; часы телефона «отстают».
      hub.clock.advance(const Duration(minutes: 5, seconds: 1));
      await expectLater(
        phone.pairing.pairWithPayload(qr),
        throwsPairing(PairingError.codeRejected),
      );
      expect(await hub.server.devices(), isEmpty);
    });

    test('истёкший QR отклоняется ещё на телефоне', () async {
      final qr = hub.qr();
      final late = PairingClient(
        db: phone.db,
        repository: phone.repo,
        store: phone.store,
        deviceName: () async => 'x',
        now: () => DateTime.now().add(const Duration(minutes: 6)),
      );
      expect(
        () => late.parsePayload(qr.encode()),
        throwsPairing(PairingError.codeRejected),
      );
      await expectLater(
        late.pairWithPayload(qr),
        throwsPairing(PairingError.codeRejected),
      );
    });

    test('лимит попыток: шестая за минуту — отказ', () async {
      final qr = hub.qr();
      PairingQrPayload wrong() => PairingQrPayload(
            serverId: qr.serverId,
            serverName: qr.serverName,
            host: qr.host,
            ips: qr.ips,
            port: qr.port,
            code: randomSecret(16),
            fingerprint: qr.fingerprint,
            exp: qr.exp,
          );
      for (var i = 0; i < 5; i++) {
        await expectLater(
          phone.pairing.pairWithPayload(wrong()),
          throwsPairing(PairingError.codeRejected),
        );
      }
      // Даже верный код сейчас не пройдёт.
      await expectLater(
        phone.pairing.pairWithPayload(qr),
        throwsPairing(PairingError.rateLimited),
      );
      // Через минуту — снова можно.
      hub.clock.advance(const Duration(seconds: 61));
      await phone.pairing.pairWithPayload(qr);
      expect(await hub.server.devices(), hasLength(1));
    });

    test('ПК с другим server_id не подходит', () async {
      final qr = hub.qr();
      final other = PairingQrPayload(
        serverId: 'another-server',
        serverName: qr.serverName,
        host: qr.host,
        ips: qr.ips,
        port: qr.port,
        code: qr.code,
        fingerprint: qr.fingerprint,
        exp: qr.exp,
      );
      await expectLater(
        phone.pairing.pairWithPayload(other),
        throwsPairing(PairingError.notFound),
      );
    });

    test('ручной ввод адреса и кода', () async {
      final code = hub.server.pairing.newCode();
      final input = phone.pairing.parseManual(
        ' 127.0.0.1:${hub.server.port} ',
        ' ${code.code} ',
      );
      expect(input, isA<ManualAddress>());
      final manual = input as ManualAddress;

      final link = await phone.pairing.pairManually(
        manual.endpoint,
        manual.code,
      );
      expect(link.serverId, hub.server.serverId);
      expect(link.fingerprint, identity.fingerprint);
      expect(await hub.server.devices(), hasLength(1));

      await phone.repo.create(title: 'После ручной привязки');
      expect(await phone.client.sync(), SyncResult.ok);
      expect((await hub.allCards()).single.title, 'После ручной привязки');
    });

    test('ручной ввод: неверный код', () async {
      hub.server.pairing.newCode();
      await expectLater(
        phone.pairing.pairManually(hub.endpoint, 'wrong-code'),
        throwsPairing(PairingError.codeRejected),
      );
      expect(await phone.store.token(), isNull);
    });

    test('ручной ввод: строка mkanban:// разбирается как QR', () {
      final qr = hub.qr();
      final input = phone.pairing.parseManual(qr.encode(), '');
      expect(input, isA<ManualPayload>());
      expect((input as ManualPayload).payload, qr);
      expect(
        () => phone.pairing.parseManual('не адрес', 'x'),
        throwsPairing(PairingError.invalidInput),
      );
      expect(
        () => phone.pairing.parseManual('192.168.1.2', ''),
        throwsPairing(PairingError.invalidInput),
      );
      final byDefaultPort =
          phone.pairing.parseManual('192.168.1.2', 'abc') as ManualAddress;
      expect(byDefaultPort.endpoint, const Endpoint('192.168.1.2', 47321));
    });
  });

  group('синхронизация', () {
    setUp(pair);

    test('без привязки ничего не делает', () async {
      final fresh = await Phone.create();
      addTearDown(fresh.close);
      expect(await fresh.client.sync(), SyncResult.notPaired);
      expect(fresh.client.status.value.phase, SyncPhase.notPaired);
    });

    test('в обе стороны', () async {
      final fromPhone = await phone.repo.create(
        title: 'С телефона',
        description: 'Описание',
        column: BoardColumn.doing,
      );
      final fromHub = await hub.repo.create(title: 'С компьютера');

      // Доска на ПК обновляется сама — через поток репозитория.
      final hubBoards = <BoardSnapshot>[];
      final sub = hub.repo.watchBoard().listen(hubBoards.add);
      addTearDown(sub.cancel);

      expect(await phone.client.sync(), SyncResult.ok);

      final onHub = await hub.repo.getCard(fromPhone.id);
      expect(onHub, isNotNull);
      expect(onHub!.title, 'С телефона');
      expect(onHub.description, 'Описание');
      expect(onHub.column, BoardColumn.doing);
      expect(onHub.serverSeq, greaterThan(0));

      final onPhone = await phone.repo.getCard(fromHub.id);
      expect(onPhone, isNotNull);
      expect(onPhone!.title, 'С компьютера');

      await expectConverged(hub, phone);
      expect(await phone.outboxCount(), 0);
      expect(await MetaDao(phone.db).cursor(), await MetaDao(hub.db).seqCounter());

      await Future<void>.delayed(Duration.zero);
      expect(hubBoards.last.length, 2);
      expect(
        hubBoards.last.cards(BoardColumn.doing).single.title,
        'С телефона',
      );

      final status = phone.client.status.value;
      expect(status.phase, SyncPhase.synced);
      expect(status.lastSyncAt, isNotNull);
      expect((await hub.server.devices()).single.lastSyncAt, isNotNull);
    });

    test('конфликт разных полей: обе правки сохраняются', () async {
      final card = await hub.repo.create(title: 'Исходное');
      await phone.client.sync();

      await phone.repo.update(card.id, title: 'Новое название');
      await hub.repo.move(card.id, column: BoardColumn.done);
      expect(await phone.client.sync(), SyncResult.ok);

      for (final repo in [hub.repo, phone.repo]) {
        final merged = (await repo.getCard(card.id))!;
        expect(merged.title, 'Новое название');
        expect(merged.column, BoardColumn.done);
      }
      await expectConverged(hub, phone);
    });

    test('конфликт одного поля: побеждает более поздняя правка', () async {
      final card = await hub.repo.create(title: 'Исходное');
      await phone.client.sync();

      await phone.repo.update(card.id, title: 'С телефона (раньше)');
      // Правка на ПК — заведомо позже по часам.
      hub.clock.advance(const Duration(seconds: 30));
      await hub.repo.update(card.id, title: 'С компьютера (позже)');
      expect(await phone.client.sync(), SyncResult.ok);

      expect((await hub.repo.getCard(card.id))!.title, 'С компьютера (позже)');
      expect(
        (await phone.repo.getCard(card.id))!.title,
        'С компьютера (позже)',
      );
      await expectConverged(hub, phone);
    });

    test('удаление распространяется в обе стороны', () async {
      final a = await hub.repo.create(title: 'Удалят на телефоне');
      final b = await hub.repo.create(title: 'Удалят на компьютере');
      await phone.client.sync();

      await phone.repo.delete(a.id);
      await hub.repo.delete(b.id);
      expect(await phone.client.sync(), SyncResult.ok);

      expect((await hub.repo.getCard(a.id))!.deleted, isTrue);
      expect((await phone.repo.getCard(b.id))!.deleted, isTrue);
      expect((await hub.repo.loadBoard()).length, 0);
      expect((await phone.repo.loadBoard()).length, 0);
      await expectConverged(hub, phone);

      // Восстановление тоже доезжает.
      await phone.repo.restore(a.id);
      await phone.client.sync();
      expect((await hub.repo.getCard(a.id))!.deleted, isFalse);
    });

    test('повторная отправка тех же изменений идемпотентна', () async {
      final card = await phone.repo.create(title: 'Один раз');
      final change = (await OutboxDao(phone.db).pending()).single;
      final token = (await phone.store.token())!;
      final api = HttpSyncApi(fingerprint: identity.fingerprint);
      addTearDown(api.close);

      final first = await api.sync(
        hub.endpoint,
        token,
        SyncRequest(cursor: 0, changes: [change]),
      );
      expect(first.applied, [change.changeId]);
      final seqAfterFirst = await MetaDao(hub.db).seqCounter();
      final afterFirst = contentOf(await hub.allCards());

      // Ответ «потерялся» — клиент отправляет то же самое ещё раз.
      final second = await api.sync(
        hub.endpoint,
        token,
        SyncRequest(cursor: 0, changes: [change]),
      );
      expect(second.applied, [change.changeId]);
      expect(await MetaDao(hub.db).seqCounter(), seqAfterFirst);
      expect(contentOf(await hub.allCards()), afterFirst);
      expect(await CardDao(hub.db).count(), 1);
      expect((await hub.repo.getCard(card.id))!.title, 'Один раз');

      // И обычный цикл клиента после этого чистит outbox.
      expect(await phone.client.sync(), SyncResult.ok);
      expect(await phone.outboxCount(), 0);
      expect(await MetaDao(hub.db).seqCounter(), seqAfterFirst);
    });

    test('некорректное изменение пропускается, остальные применяются',
        () async {
      final token = (await phone.store.token())!;
      final good = diffToChange(
        null,
        await phone.repo.create(title: 'Хорошее'),
        changeId: 'good-1',
      )!;
      final bad = {
        ...good.toJson(),
        'change_id': 'bad-1',
        'id': 'other-card',
        'fields': {'title': ''},
        'hlc': {'title': good.hlc['title'].toString()},
      };
      final response = await hub.server.handler(
        shelf.Request(
          'POST',
          Uri.parse('https://localhost/v1/sync'),
          headers: {'authorization': 'Bearer $token'},
          body: jsonEncode({
            'cursor': 0,
            'changes': [bad, good.toJson(), 'мусор'],
          }),
        ),
      );
      expect(response.statusCode, 200);
      final body = SyncResponse.fromJson(
        jsonDecode(await response.readAsString()),
      );
      expect(body.applied, ['good-1']);
      expect((await hub.allCards()).single.title, 'Хорошее');
    });

    test('400 на некорректный запрос', () async {
      final token = (await phone.store.token())!;
      Future<int> post(Object? body) async => (await hub.server.handler(
            shelf.Request(
              'POST',
              Uri.parse('https://localhost/v1/sync'),
              headers: {'authorization': 'Bearer $token'},
              body: body is String ? body : jsonEncode(body),
            ),
          ))
              .statusCode;

      expect(await post('не json'), 400);
      expect(await post([1, 2]), 400);
      expect(await post({'cursor': -1, 'changes': <Object>[]}), 400);
      expect(await post({'cursor': 0, 'changes': 'x'}), 400);
      expect(await post({'cursor': 0, 'limit': 501}), 400);
      expect(
        await post({
          'cursor': 0,
          'changes': List.filled(maxSyncLimit + 1, <String, Object>{}),
        }),
        400,
      );
      expect(await post({'cursor': 0}), 200);
    });

    test('401 без токена и с неизвестным токеном', () async {
      Future<shelf.Response> post(Map<String, String> headers) =>
          Future.value(
            hub.server.handler(
              shelf.Request(
                'POST',
                Uri.parse('https://localhost/v1/sync'),
                headers: headers,
                body: jsonEncode({'cursor': 0, 'changes': <Object>[]}),
              ),
            ),
          );

      final none = await post({});
      expect(none.statusCode, 401);
      expect(jsonDecode(await none.readAsString()), containsPair('reason', 'unknown'));

      final api = HttpSyncApi(fingerprint: identity.fingerprint);
      addTearDown(api.close);
      await expectLater(
        api.sync(hub.endpoint, randomSecret(32), const SyncRequest(cursor: 0)),
        throwsA(
          isA<SyncUnauthorizedException>()
              .having((e) => e.reason, 'reason', 'unknown'),
        ),
      );
    });

    test('после отзыва — 401 revoked, клиент «Отвязано»', () async {
      await phone.repo.create(title: 'До отзыва');
      expect(await phone.client.sync(), SyncResult.ok);

      await hub.server.revoke(phone.repo.deviceId);
      expect(await hub.server.devices(), isEmpty);

      final api = HttpSyncApi(fingerprint: identity.fingerprint);
      addTearDown(api.close);
      await expectLater(
        api.sync(
          hub.endpoint,
          (await phone.store.token())!,
          const SyncRequest(cursor: 0),
        ),
        throwsA(
          isA<SyncUnauthorizedException>()
              .having((e) => e.reason, 'reason', 'revoked'),
        ),
      );

      await phone.repo.create(title: 'После отзыва');
      expect(await phone.client.sync(), SyncResult.revoked);
      expect(phone.client.status.value.phase, SyncPhase.revoked);
      // Правка не потеряна и на ПК не попала.
      expect(await phone.outboxCount(), 1);
      expect(await CardDao(hub.db).count(), 1);
      // Статус переживает перезапуск.
      await phone.client.reload();
      expect(phone.client.status.value.phase, SyncPhase.revoked);

      // Новая привязка возвращает синхронизацию и доставляет правку.
      await pair();
      expect(await phone.client.sync(), SyncResult.ok);
      expect(await CardDao(hub.db).count(), 2);
      await expectConverged(hub, phone);
    });

    test('ПК недоступен — «нет связи», правки остаются в очереди', () async {
      await phone.repo.create(title: 'Офлайн');
      await hub.server.stop();

      expect(await phone.client.sync(), SyncResult.offline);
      expect(phone.client.status.value.phase, SyncPhase.offline);
      expect(await phone.outboxCount(), 1);
    });

    test('has_more: больше 500 изменений в обе стороны', () async {
      const fromHub = 1100;
      const fromPhone = 620;
      for (var i = 0; i < fromHub; i++) {
        await hub.repo.create(title: 'ПК $i');
      }
      for (var i = 0; i < fromPhone; i++) {
        await phone.repo.create(title: 'Телефон $i');
      }

      // Одна страница — не больше 500 изменений и признак продолжения.
      final api = HttpSyncApi(fingerprint: identity.fingerprint);
      addTearDown(api.close);
      final page = await api.sync(
        hub.endpoint,
        (await phone.store.token())!,
        const SyncRequest(cursor: 0),
      );
      expect(page.changes, hasLength(maxSyncLimit));
      expect(page.hasMore, isTrue);
      expect(page.cursor, maxSyncLimit);

      expect(await phone.client.sync(), SyncResult.ok);

      expect(await CardDao(hub.db).count(), fromHub + fromPhone);
      expect(await CardDao(phone.db).count(), fromHub + fromPhone);
      expect(await phone.outboxCount(), 0);
      await expectConverged(hub, phone);
    });

    test('410: устаревший курсор → полный reset', () async {
      final keep = await hub.repo.create(title: 'Останется');
      final doomed = await hub.repo.create(title: 'Удалят и вычистят');
      expect(await phone.client.sync(), SyncResult.ok);
      final oldCursor = await MetaDao(phone.db).cursor();

      // ПК удаляет карточку; через 90+ дней её tombstone вычищается.
      await hub.repo.delete(doomed.id);
      hub.clock.advance(const Duration(days: 91));
      final floor = await hub.server.runMaintenance();
      expect(floor, greaterThan(oldCursor));
      expect(await hub.repo.getCard(doomed.id), isNull);

      // Сам запрос со старым курсором получает 410.
      final api = HttpSyncApi(fingerprint: identity.fingerprint);
      addTearDown(api.close);
      await expectLater(
        api.sync(
          hub.endpoint,
          (await phone.store.token())!,
          SyncRequest(cursor: oldCursor),
        ),
        throwsA(isA<SyncGoneException>()),
      );

      // У телефона за это время появилась своя неотправленная карточка.
      final local = await phone.repo.create(title: 'Новая с телефона');
      expect((await phone.repo.getCard(doomed.id))!.deleted, isFalse);

      expect(await phone.client.sync(), SyncResult.ok);

      // Вычищенная на ПК карточка исчезла и с телефона, остальное на месте.
      expect(await phone.repo.getCard(doomed.id), isNull);
      expect((await phone.repo.getCard(keep.id))!.title, 'Останется');
      expect((await phone.repo.getCard(local.id))!.title, 'Новая с телефона');
      expect((await hub.repo.getCard(local.id))!.title, 'Новая с телефона');
      expect(await phone.store.resetPending(), isFalse);
      expect(await phone.outboxCount(), 0);
      await expectConverged(hub, phone);

      // Следующий обмен — обычный.
      expect(await phone.client.sync(), SyncResult.ok);
    });

    test('два телефона сходятся через ПК', () async {
      final second = await Phone.create(name: 'Второй');
      addTearDown(second.close);
      await pair(second);

      final card = await phone.repo.create(title: 'От первого');
      await phone.client.sync();
      await second.client.sync();
      expect((await second.repo.getCard(card.id))!.title, 'От первого');

      await second.repo.move(card.id, column: BoardColumn.doing);
      await second.client.sync();
      await phone.client.sync();
      expect((await phone.repo.getCard(card.id))!.column, BoardColumn.doing);
      expect(await hub.server.devices(), hasLength(2));
      await expectConverged(hub, phone);
      await expectConverged(hub, second);
    });

    test('привязка к другому ПК: карточки отправляются заново', () async {
      await phone.repo.create(title: 'Уже синхронизирована');
      expect(await phone.client.sync(), SyncResult.ok);
      expect(await phone.outboxCount(), 0);

      final otherHub = await Hub.start(CertService.generate());
      addTearDown(otherHub.close);
      await phone.pairing.pairWithPayload(otherHub.qr());
      expect(await MetaDao(phone.db).cursor(), 0);

      expect(await phone.client.sync(), SyncResult.ok);
      expect(
        (await otherHub.allCards()).single.title,
        'Уже синхронизирована',
      );
      await expectConverged(otherHub, phone);
    });

    test('отвязка на телефоне', () async {
      await phone.client.unpair();
      expect(phone.client.status.value.phase, SyncPhase.notPaired);
      expect(await phone.store.token(), isNull);
      expect(await phone.client.sync(), SyncResult.notPaired);
      // Запись на ПК остаётся, пока её не уберут там.
      expect(await DeviceDao(hub.db).all(), hasLength(1));
    });
  });
}

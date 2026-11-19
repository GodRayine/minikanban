/// Реализация [BoardRepository] поверх SQLite.
library;

import 'dart:async';

import 'package:sqflite_common/sqlite_api.dart';

import '../core/fractional_index.dart';
import '../core/hlc.dart';
import '../core/ids.dart';
import '../core/platform_role.dart';
import '../domain/board_repository.dart';
import '../domain/card.dart';
import '../sync/protocol/dto.dart';
import '../sync/protocol/merge.dart';
import 'card_dao.dart';
import 'meta_dao.dart';
import 'outbox_dao.dart';

/// Итог [BoardRepositoryImpl.applyRemote].
final class ApplyRemoteResult {
  const ApplyRemoteResult({required this.accepted, required this.changedCards});

  /// `change_id` всех обработанных изменений, включая уже известные
  /// (повторы) и ничего не изменившие — хаб возвращает их клиенту как
  /// `applied`.
  final List<String> accepted;

  /// Сколько раз слияние реально изменило карточку.
  final int changedCards;
}

/// Хранилище доски в локальной БД.
///
/// Каждая локальная правка — одна транзакция: карточка получает новые
/// HLC-метки, последняя метка часов сохраняется в `meta`, и
/// * на клиенте изменение ([diffToChange]) кладётся в outbox;
/// * на хабе карточке назначается следующий `server_seq` — клиенты
///   забирают изменения по курсору прямо из таблицы карточек, поэтому
///   outbox хабу не нужен.
///
/// После каждой записи поток [watchBoard] получает свежий снимок.
class BoardRepositoryImpl implements BoardRepository {
  BoardRepositoryImpl._(this._db, this.role, this._clock, this._now);

  /// Создаёт репозиторий: при первом запуске генерирует `device_id`,
  /// восстанавливает HLC-часы из `meta.hlc_last`.
  ///
  /// [now] — источник времени в мс (для тестов).
  static Future<BoardRepositoryImpl> open(
    Database db, {
    required PlatformRole role,
    int Function()? now,
  }) async {
    final clockNow = now ?? _systemNow;
    final clock = await db.transaction((txn) async {
      final meta = MetaDao(txn);
      return HlcClock(
        nodeId: await meta.ensureDeviceId(),
        last: await meta.hlcLast(),
        now: clockNow,
      );
    });
    return BoardRepositoryImpl._(db, role, clock, clockNow);
  }

  final Database _db;
  final PlatformRole role;
  final HlcClock _clock;
  final int Function() _now;

  final StreamController<BoardSnapshot> _snapshots =
      StreamController<BoardSnapshot>.broadcast();
  final StreamController<void> _localChanges =
      StreamController<void>.broadcast();
  BoardSnapshot? _latest;
  bool _loading = false;

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  /// Идентификатор этого устройства (он же nodeId HLC-меток).
  String get deviceId => _clock.nodeId;

  /// Событие после каждой локальной правки (не после синхронизации) —
  /// по нему клиент планирует отправку изменений.
  Stream<void> get localChanges => _localChanges.stream;

  /// Перечитывает доску из БД и рассылает снимок: БД могла измениться
  /// в обход репозитория (фоновая синхронизация в другом изоляте).
  Future<void> refresh() => _refresh();

  // --- Чтение ---------------------------------------------------------------

  @override
  Stream<BoardSnapshot> watchBoard() => Stream.multi((listener) {
        final sub = _snapshots.stream.listen(
          listener.addSync,
          onError: listener.addErrorSync,
          onDone: listener.closeSync,
        );
        listener.onCancel = sub.cancel;
        final latest = _latest;
        if (latest != null) {
          listener.add(latest);
        } else if (!_loading) {
          unawaited(_refresh());
        }
      });

  /// Текущий снимок доски напрямую из БД.
  Future<BoardSnapshot> loadBoard() async =>
      BoardSnapshot.fromCards(await CardDao(_db).active());

  /// Карточка по id (включая удалённые) или `null`.
  Future<KanbanCard?> getCard(String id) => CardDao(_db).getById(id);

  Future<void> _refresh() async {
    if (_snapshots.isClosed) return;
    _loading = true;
    try {
      final snapshot = await loadBoard();
      _latest = snapshot;
      if (!_snapshots.isClosed) _snapshots.add(snapshot);
    } on Object catch (error, stack) {
      if (!_snapshots.isClosed) _snapshots.addError(error, stack);
    } finally {
      _loading = false;
    }
  }

  // --- Локальные правки -----------------------------------------------------

  @override
  Future<KanbanCard> create({
    required String title,
    String description = '',
    BoardColumn column = BoardColumn.todo,
  }) async {
    final card = await _db.transaction((txn) async {
      final cards = CardDao(txn);
      final created = KanbanCard.create(
        id: newId(),
        title: title,
        description: description,
        column: column,
        pos: keyBetween(await cards.lastPos(column), null),
        createdAt: _now(),
        hlc: _clock.send(),
      );
      return _commit(txn, null, created);
    });
    await _refresh();
    _notifyLocalChange();
    return card;
  }

  @override
  Future<KanbanCard> update(String id, {String? title, String? description}) =>
      _edit(
        id,
        (txn, card, hlc) async =>
            card.edit(hlc: hlc, title: title, description: description),
      );

  /// Неизвестные (например, уже удалённые синхронизацией) [beforeId] и
  /// [afterId] не считаются ошибкой: карточка встаёт в конец колонки.
  @override
  Future<KanbanCard> move(
    String id, {
    required BoardColumn column,
    String? beforeId,
    String? afterId,
  }) =>
      _edit(id, (txn, card, hlc) async {
        final all = await CardDao(txn).activeInColumn(column);
        final others = [
          for (final c in all)
            if (c.id != id) c,
        ];

        var index = others.length;
        final after =
            afterId == null ? -1 : others.indexWhere((c) => c.id == afterId);
        final before =
            beforeId == null ? -1 : others.indexWhere((c) => c.id == beforeId);
        if (after >= 0) {
          index = after + 1;
        } else if (before >= 0) {
          index = before;
        }

        // Карточка уже стоит на этом месте — порядок не трогаем.
        if (!card.deleted &&
            card.column == column &&
            all.indexWhere((c) => c.id == id) == index) {
          return card;
        }

        final lower = index > 0 ? others[index - 1].pos : null;
        // Ключи могут совпасть после слияния параллельных правок: берём
        // ближайший строго больший, чтобы интервал был непустым.
        String? upper;
        for (var i = index; i < others.length; i++) {
          if (lower == null || others[i].pos.compareTo(lower) > 0) {
            upper = others[i].pos;
            break;
          }
        }
        return card.edit(
          hlc: hlc,
          column: column,
          pos: keyBetween(lower, upper),
        );
      });

  @override
  Future<void> delete(String id) =>
      _edit(id, (txn, card, hlc) async => card.edit(hlc: hlc, deleted: true));

  @override
  Future<KanbanCard> restore(String id) =>
      _edit(id, (txn, card, hlc) async => card.edit(hlc: hlc, deleted: false));

  /// Общая часть правок существующей карточки.
  Future<KanbanCard> _edit(
    String id,
    Future<KanbanCard> Function(Transaction txn, KanbanCard card, Hlc hlc)
        change,
  ) async {
    var changed = false;
    final card = await _db.transaction((txn) async {
      final before = await CardDao(txn).getById(id);
      if (before == null) throw StateError('Карточка $id не найдена');
      final after = await change(txn, before, _clock.send());
      if (after == before) return before;
      changed = true;
      return _commit(txn, before, after);
    });
    if (changed) {
      await _refresh();
      _notifyLocalChange();
    }
    return card;
  }

  void _notifyLocalChange() {
    if (!_localChanges.isClosed) _localChanges.add(null);
  }

  /// Записывает результат локальной правки `before → after`.
  Future<KanbanCard> _commit(
    Transaction txn,
    KanbanCard? before,
    KanbanCard after,
  ) async {
    final meta = MetaDao(txn);
    var saved = after;
    if (role.isHub) {
      saved = after.copyWith(serverSeq: await meta.nextServerSeq());
    } else {
      final change = diffToChange(before, after, changeId: newId());
      if (change != null) {
        await OutboxDao(txn).add(change, createdAt: _now());
      }
    }
    await CardDao(txn).upsert(saved);
    await meta.setHlcLast(_clock.last);
    return saved;
  }

  // --- Синхронизация --------------------------------------------------------

  /// Применяет изменения, пришедшие с другого устройства, одной
  /// транзакцией через [mergeCard] (LWW по полям).
  ///
  /// Идемпотентно: повтор тех же изменений ничего не меняет. На хабе
  /// `change_id` дополнительно запоминаются в `applied_changes`, а каждой
  /// реально изменившейся карточке назначается новый `server_seq`.
  ///
  /// Некорректное изменение ([ProtocolException]) откатывает весь пакет.
  ///
  /// [within] выполняется в той же транзакции после слияния: клиент
  /// сдвигает в нём курсор и чистит outbox, чтобы обрыв посреди
  /// синхронизации не оставил БД в промежуточном состоянии.
  Future<ApplyRemoteResult> applyRemote(
    List<CardChange> changes, {
    Future<void> Function(Transaction txn)? within,
  }) async {
    if (changes.isEmpty && within == null) {
      return const ApplyRemoteResult(accepted: [], changedCards: 0);
    }
    var changedCards = 0;
    final accepted = await _db.transaction((txn) async {
      final cards = CardDao(txn);
      final meta = MetaDao(txn);
      final applied = AppliedChangesDao(txn);
      final ids = <String>[];

      for (final change in changes) {
        ids.add(change.changeId);
        if (role.isHub && await applied.contains(change.changeId)) continue;

        final local = await cards.getById(change.id);
        final result = mergeCard(local, change);
        if (result.changed) {
          changedCards++;
          await cards.upsert(
            role.isHub
                ? result.card.copyWith(serverSeq: await meta.nextServerSeq())
                : result.card,
          );
        }
        if (role.isHub) {
          await applied.add(change.changeId, appliedAt: _now());
        }
        _observe(change);
      }
      if (changes.isNotEmpty) await meta.setHlcLast(_clock.last);
      if (within != null) await within(txn);
      return ids;
    });
    if (changedCards > 0) await _refresh();
    return ApplyRemoteResult(accepted: accepted, changedCards: changedCards);
  }

  /// Клиент: кладёт в outbox полное состояние всех карточек (включая
  /// tombstone). Нужно при привязке к другому ПК — новый хаб ничего не
  /// знает о карточках, уже подтверждённых прежним. Возвращает число
  /// поставленных в очередь изменений.
  Future<int> enqueueFullState() async {
    if (role.isHub) return 0;
    return _db.transaction((txn) async {
      final outbox = OutboxDao(txn);
      var count = 0;
      for (final card in await CardDao(txn).all()) {
        final change = diffToChange(null, card, changeId: newId());
        if (change == null) continue;
        await outbox.add(change, createdAt: _now());
        count++;
      }
      return count;
    });
  }

  /// Клиент, завершение полного reset (410): удаляет карточки, которых
  /// нет на хабе ([serverIds] — всё, что он прислал с нулевого курсора)
  /// и у которых нет неотправленных правок. Так исчезают карточки, чьи
  /// tombstone хаб уже вычистил. [within] — в той же транзакции.
  Future<int> pruneMissing(
    Set<String> serverIds, {
    Future<void> Function(Transaction txn)? within,
  }) async {
    final removed = await _db.transaction((txn) async {
      final cards = CardDao(txn);
      final pending = {
        for (final change in await OutboxDao(txn).pending()) change.id,
      };
      final stale = [
        for (final id in await cards.allIds())
          if (!serverIds.contains(id) && !pending.contains(id)) id,
      ];
      await cards.deleteByIds(stale);
      if (within != null) await within(txn);
      return stale.length;
    });
    if (removed > 0) await _refresh();
    return removed;
  }

  /// Подтягивает локальные часы к меткам входящего изменения, чтобы
  /// следующие локальные правки были новее уже увиденных.
  void _observe(CardChange change) {
    Hlc? top;
    for (final stamp in change.hlc.values) {
      if (top == null || stamp > top) top = stamp;
    }
    if (top == null) return;
    try {
      _clock.receive(top);
    } on HlcDriftException {
      // Метка из далёкого будущего: данные уже слиты детерминированно,
      // но локальные часы ею не «отравляем».
    }
  }

  /// Закрывает поток снимков. Саму БД закрывает её владелец.
  Future<void> dispose() async {
    await _localChanges.close();
    await _snapshots.close();
  }
}

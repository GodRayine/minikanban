/// Клиент синхронизации (телефон): один цикл обмена с ПК и его статус.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../../data/board_repository_impl.dart';
import '../../data/meta_dao.dart';
import '../../data/outbox_dao.dart';
import '../protocol/dto.dart';
import '../sync_status.dart';
import 'client_store.dart';
import 'host_resolver.dart';
import 'sync_api.dart';

/// Итог одного запуска [SyncClient.sync].
enum SyncResult {
  ok,
  notPaired,

  /// ПК недоступен — стоит повторить позже.
  offline,
  revoked,
  certError,
  incompatible,
}

class SyncClient {
  SyncClient({
    required Database db,
    required BoardRepositoryImpl repository,
    required this.store,
    SyncApiFactory apiFactory = defaultSyncApiFactory,
    ServiceDiscovery? discover,
    DateTime Function()? now,
  })  : _db = db,
        _repository = repository,
        _apiFactory = apiFactory,
        _discover = discover,
        _now = now ?? DateTime.now;

  final Database _db;
  final BoardRepositoryImpl _repository;
  final SyncApiFactory _apiFactory;
  final ServiceDiscovery? _discover;
  final DateTime Function() _now;

  final ClientStore store;

  /// Текущий статус для интерфейса.
  final ValueNotifier<SyncStatus> status =
      ValueNotifier(const SyncStatus(SyncPhase.notPaired));

  Future<SyncResult>? _running;

  /// Предохранитель от бесконечного цикла при некорректном сервере.
  static const int _maxRounds = 100000;

  /// Перечитывает привязку и время последней синхронизации из БД
  /// (при запуске, после привязки/отвязки, после фонового обмена).
  Future<void> reload() async {
    if (_running != null) return;
    status.value = await _idleStatus();
  }

  Future<SyncStatus> _idleStatus() async {
    final link = await store.link();
    if (link == null || await store.token() == null) {
      return const SyncStatus(SyncPhase.notPaired);
    }
    final last = await store.lastSyncAt();
    if (await store.syncBlock() != null) {
      return SyncStatus(SyncPhase.revoked, lastSyncAt: last);
    }
    // Привязан, но ещё ни разу не обменивался — связи пока не было.
    return SyncStatus(
      last == null ? SyncPhase.offline : SyncPhase.synced,
      lastSyncAt: last,
    );
  }

  /// Привязанный ПК (для настроек).
  Future<ServerLink?> link() => store.link();

  /// Забывает запомненный адрес ПК и ищет его в сети заново.
  Future<SyncResult> rediscover() async {
    await _running;
    await store.forgetLastGood();
    return sync();
  }

  /// Отвязывает телефон от ПК. Локальные задачи остаются.
  Future<void> unpair() async {
    await store.clearLink();
    status.value = const SyncStatus(SyncPhase.notPaired);
  }

  /// Один обмен с ПК. Параллельные вызовы получают результат уже
  /// идущего обмена. Не бросает исключений.
  Future<SyncResult> sync() =>
      _running ??= _run().whenComplete(() => _running = null);

  Future<SyncResult> _run() async {
    final link = await store.link();
    final token = await store.token();
    if (link == null || token == null) {
      status.value = const SyncStatus(SyncPhase.notPaired);
      return SyncResult.notPaired;
    }
    final last = await store.lastSyncAt();
    if (await store.syncBlock() != null) {
      status.value = SyncStatus(SyncPhase.revoked, lastSyncAt: last);
      return SyncResult.revoked;
    }

    status.value = SyncStatus(SyncPhase.syncing, lastSyncAt: last);
    SyncResult finish(SyncPhase phase, SyncResult result) {
      status.value = SyncStatus(phase, lastSyncAt: last);
      return result;
    }

    final api = _apiFactory(link.fingerprint);
    try {
      final resolved = await HostResolver(
        probe: (endpoint, timeout) => api.hello(endpoint, timeout: timeout),
        discover: _discover,
      ).resolve(
        serverId: link.serverId,
        lastGood: link.lastGood,
        hostName: link.host,
        ips: link.ips,
        port: link.port,
      );
      debugPrint(
        'Sync: ПК найден (${resolved.source.name}) по адресу '
        '${resolved.endpoint}',
      );
      await _exchange(api, resolved.endpoint, token);
      final at = _now();
      await store.markSuccess(resolved.endpoint, at);
      status.value = SyncStatus(SyncPhase.synced, lastSyncAt: at);
      return SyncResult.ok;
    } on SyncUnauthorizedException {
      // И `revoked`, и `unknown` означают одно: этот токен ПК больше не
      // примет, нужна новая привязка.
      await store.setSyncBlock('revoked');
      return finish(SyncPhase.revoked, SyncResult.revoked);
    } on SyncCertException {
      return finish(SyncPhase.certError, SyncResult.certError);
    } on SyncIncompatibleException {
      return finish(SyncPhase.incompatible, SyncResult.incompatible);
    } on SyncException {
      return finish(SyncPhase.offline, SyncResult.offline);
    } on Object catch (error, stack) {
      debugPrint('SyncClient: сбой синхронизации: $error\n$stack');
      return finish(SyncPhase.offline, SyncResult.offline);
    } finally {
      api.close();
    }
  }

  /// Обмен до полного опустошения очереди и выдачи сервера.
  Future<void> _exchange(SyncApi api, Endpoint endpoint, String token) async {
    final meta = MetaDao(_db);
    final outbox = OutboxDao(_db);

    var resetting = await store.resetPending();
    var cursor = resetting ? 0 : await meta.cursor();
    var resetsLeft = 2;

    /// Карточки, присланные сервером в ходе полного reset.
    final seen = <String>{};

    /// Отправленные, но не принятые сервером изменения: остаются в
    /// outbox, но в этом запуске повторно не отправляются.
    final rejected = <String>{};

    Future<List<CardChange>> nextBatch() async {
      final pending =
          await outbox.pending(limit: maxSyncLimit + rejected.length);
      return [
        for (final change in pending)
          if (!rejected.contains(change.changeId)) change,
      ].take(maxSyncLimit).toList();
    }

    for (var round = 0; round < _maxRounds; round++) {
      final batch = await nextBatch();
      final SyncResponse response;
      try {
        response = await api.sync(
          endpoint,
          token,
          SyncRequest(cursor: cursor, changes: batch),
        );
      } on SyncGoneException {
        // 410: курсор устарел — начинаем заново с нуля. Флаг в БД,
        // чтобы прерванный reset продолжился при следующем запуске.
        if (resetsLeft-- <= 0) {
          throw const SyncNetworkException('Сервер повторно требует reset');
        }
        await store.setResetPending();
        resetting = true;
        cursor = 0;
        seen.clear();
        continue;
      }

      final applied = response.applied.toSet();
      for (final change in batch) {
        if (!applied.contains(change.changeId)) rejected.add(change.changeId);
      }

      // Ответ применяется атомарно: карточки, курсор и чистка outbox.
      await _repository.applyRemote(
        response.changes,
        within: (txn) async {
          await MetaDao(txn).setCursor(response.cursor);
          await OutboxDao(txn).remove(response.applied);
        },
      );
      cursor = response.cursor;
      if (resetting) seen.addAll(response.changes.map((c) => c.id));

      if (response.hasMore) continue;
      if ((await nextBatch()).isEmpty) break;
    }

    if (resetting) {
      await _repository.pruneMissing(
        seen,
        within: (txn) => MetaDao(txn).remove(MetaKeys.resetPending),
      );
    }
  }

  void dispose() => status.dispose();
}

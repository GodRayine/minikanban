/// Состояние синхронизации для чипа в шапке и настроек.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import 'server/sync_server.dart';

enum SyncPhase {
  /// Всё отправлено и получено.
  synced,

  /// Идёт обмен.
  syncing,

  /// Привязка есть, но ПК недоступен.
  offline,

  /// Устройства ещё не связаны.
  notPaired,

  /// ПК отвязал этот телефон (401): нужна новая привязка.
  revoked,

  /// Сертификат ПК не совпал с отпечатком из QR.
  certError,

  /// Версии протокола на ПК и телефоне не совпадают.
  incompatible;

  /// Телефон привязан к ПК (пусть даже синхронизация сейчас невозможна).
  bool get isPaired => this != notPaired;

  /// Синхронизация остановлена до действий пользователя.
  bool get isBlocked =>
      this == revoked || this == certError || this == incompatible;
}

final class SyncStatus {
  const SyncStatus(this.phase, {this.lastSyncAt});

  final SyncPhase phase;

  /// Время последней успешной синхронизации.
  final DateTime? lastSyncAt;

  @override
  bool operator ==(Object other) =>
      other is SyncStatus &&
      other.phase == phase &&
      other.lastSyncAt == lastSyncAt;

  @override
  int get hashCode => Object.hash(phase, lastSyncAt);

  @override
  String toString() => 'SyncStatus(${phase.name}, $lastSyncAt)';
}

/// Статус для интерфейса.
///
/// * Телефон: повторяет состояние `SyncClient`.
/// * ПК: «Телефон не подключён», пока нет привязанных устройств, иначе —
///   время последней синхронизации любого из телефонов.
class SyncStatusController extends Notifier<SyncStatus> {
  bool _alive = false;

  @override
  SyncStatus build() {
    _alive = true;
    ref.onDispose(() => _alive = false);

    if (ref.watch(platformRoleProvider).isHub) {
      final server = ref.watch(syncServerProvider);
      if (server == null) return const SyncStatus(SyncPhase.notPaired);
      final sub = server.deviceEvents.listen((_) => _reloadHub(server));
      ref.onDispose(sub.cancel);
      unawaited(_reloadHub(server));
      return stateOrNull ?? const SyncStatus(SyncPhase.notPaired);
    }

    final client = ref.watch(syncClientProvider);
    if (client == null) return const SyncStatus(SyncPhase.notPaired);
    void listener() {
      if (_alive) state = client.status.value;
    }

    client.status.addListener(listener);
    ref.onDispose(() => client.status.removeListener(listener));
    return client.status.value;
  }

  Future<void> _reloadHub(SyncServer server) async {
    try {
      final devices = await server.devices();
      if (!_alive) return;
      if (devices.isEmpty) {
        state = const SyncStatus(SyncPhase.notPaired);
        return;
      }
      int? last;
      for (final device in devices) {
        final at = device.lastSyncAt;
        if (at != null && (last == null || at > last)) last = at;
      }
      state = SyncStatus(
        SyncPhase.synced,
        lastSyncAt:
            last == null ? null : DateTime.fromMillisecondsSinceEpoch(last),
      );
    } on Object {
      // БД закрыта при завершении приложения — статус уже не нужен.
    }
  }

  /// Ручная синхронизация (кнопка, чип, pull-to-refresh).
  ///
  /// На телефоне запускает обмен с ПК. ПК сам соединений не открывает
  /// (телефоны приходят к нему), поэтому здесь лишь обновляется статус.
  Future<void> syncNow() async {
    if (ref.read(platformRoleProvider).isHub) {
      final server = ref.read(syncServerProvider);
      if (server != null) await _reloadHub(server);
      return;
    }
    final scheduler = ref.read(syncSchedulerProvider);
    if (scheduler != null) {
      await scheduler.syncNow();
    } else {
      await ref.read(syncClientProvider)?.sync();
    }
  }
}

final syncStatusProvider = NotifierProvider<SyncStatusController, SyncStatus>(
    SyncStatusController.new);

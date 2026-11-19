/// Расписание синхронизации на телефоне, пока приложение на экране:
/// при открытии/возврате, каждые 5 минут, через ~3 с после локальной
/// правки и вручную. При недоступном ПК — повторы 5 → 15 → 60 с.
/// (В фоне раз в 15 минут синхронизацию запускает WorkManager.)
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'sync_client.dart';

class SyncScheduler with WidgetsBindingObserver {
  SyncScheduler({
    required Future<SyncResult> Function() sync,
    Stream<void>? localChanges,
    Future<void> Function()? onForeground,
    this.period = const Duration(minutes: 5),
    this.debounce = const Duration(seconds: 3),
    this.backoff = const [
      Duration(seconds: 5),
      Duration(seconds: 15),
      Duration(seconds: 60),
    ],
  })  : _sync = sync,
        _localChanges = localChanges,
        _onForeground = onForeground;

  final Future<SyncResult> Function() _sync;
  final Stream<void>? _localChanges;
  final Future<void> Function()? _onForeground;

  /// Период синхронизации при открытом приложении.
  final Duration period;

  /// Задержка после локальной правки.
  final Duration debounce;

  /// Паузы между повторами при недоступном ПК; последняя повторяется.
  final List<Duration> backoff;

  StreamSubscription<void>? _localSub;
  Timer? _periodic;
  Timer? _debounceTimer;
  Timer? _retryTimer;
  int _failures = 0;
  bool _foreground = false;
  bool _attached = false;

  /// Начинает работу: подписывается на жизненный цикл приложения и
  /// сразу синхронизируется.
  void start() {
    if (!_attached) {
      _attached = true;
      WidgetsBinding.instance.addObserver(this);
    }
    _localSub ??= _localChanges?.listen((_) => notifyLocalChange());
    enterForeground();
  }

  void dispose() {
    if (_attached) {
      _attached = false;
      WidgetsBinding.instance.removeObserver(this);
    }
    unawaited(_localSub?.cancel());
    _localSub = null;
    enterBackground();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        enterForeground();
      case AppLifecycleState.paused ||
            AppLifecycleState.hidden ||
            AppLifecycleState.detached:
        enterBackground();
      case AppLifecycleState.inactive:
        // Кратковременная потеря фокуса (шторка, диалог разрешения).
        break;
    }
  }

  /// Приложение на экране: синхронизация сейчас и далее по таймеру.
  void enterForeground() {
    if (_foreground) return;
    _foreground = true;
    _failures = 0;
    _periodic = Timer.periodic(period, (_) => unawaited(_run()));
    unawaited(() async {
      try {
        await _onForeground?.call();
      } on Object {
        // Обновление экрана не должно мешать синхронизации.
      }
      if (_foreground) await _run();
    }());
  }

  /// Приложение ушло с экрана: таймеры останавливаются.
  void enterBackground() {
    _foreground = false;
    _periodic?.cancel();
    _periodic = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  /// Локальная правка: синхронизация через [debounce] после последней.
  void notifyLocalChange() {
    if (!_foreground) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () => unawaited(_run()));
  }

  /// Ручная синхронизация (чип, кнопка, pull-to-refresh).
  Future<SyncResult> syncNow() {
    _failures = 0;
    return _run();
  }

  Future<SyncResult> _run() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    final result = await _sync();
    if (result == SyncResult.offline) {
      if (_foreground && backoff.isNotEmpty) {
        final delay = backoff[_failures.clamp(0, backoff.length - 1)];
        _failures++;
        _retryTimer?.cancel();
        _retryTimer = Timer(delay, () => unawaited(_run()));
      }
    } else {
      _failures = 0;
    }
    return result;
  }
}

/// Разрешение Android на доступ к локальной сети (Android 16+/17:
/// `ACCESS_LOCAL_NETWORK`). Без него соединения с ПК по Wi-Fi блокируются.
library;

import 'dart:io';

import 'package:flutter/services.dart';

enum LocalNetworkStatus {
  /// Разрешение выдано.
  granted,

  /// Не выдано: соединения с ПК могут блокироваться системой.
  denied,

  /// На этой версии Android (или платформе) разрешение не требуется.
  notRequired,
}

abstract final class LocalNetworkAccess {
  static const MethodChannel _channel =
      MethodChannel('minikanban/local_network');

  static LocalNetworkStatus _parse(String? value) => switch (value) {
        'granted' => LocalNetworkStatus.granted,
        'denied' => LocalNetworkStatus.denied,
        _ => LocalNetworkStatus.notRequired,
      };

  static Future<LocalNetworkStatus> _call(String method) async {
    if (!Platform.isAndroid) return LocalNetworkStatus.notRequired;
    try {
      return _parse(await _channel.invokeMethod<String>(method));
    } on PlatformException {
      return LocalNetworkStatus.notRequired;
    } on MissingPluginException {
      return LocalNetworkStatus.notRequired;
    }
  }

  static Future<LocalNetworkStatus> status() => _call('status');

  /// Показывает системный запрос, если разрешение ещё не выдано.
  static Future<LocalNetworkStatus> request() => _call('request');
}

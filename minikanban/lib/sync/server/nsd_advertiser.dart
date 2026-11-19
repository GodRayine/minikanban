/// Объявление сервера в локальной сети через DNS-SD (`_minikanban._tcp`).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:nsd/nsd.dart' as nsd;

/// Тип сервиса DNS-SD.
const String nsdServiceType = '_minikanban._tcp';

/// Регистрирует сервис с TXT `sid=<server_id>`, `v=1`.
///
/// Обнаружение по mDNS — лишь один из путей поиска ПК, поэтому любая
/// ошибка здесь только пишется в лог: приложение продолжает работать.
class NsdAdvertiser {
  nsd.Registration? _registration;

  bool get isRegistered => _registration != null;

  /// Возвращает `true`, если сервис зарегистрирован.
  Future<bool> start({
    required String serverId,
    required String serverName,
    required int port,
  }) async {
    await stop();
    try {
      _registration = await nsd
          .register(
            nsd.Service(
              name: 'MiniKanban $serverName',
              type: nsdServiceType,
              port: port,
              txt: {
                'sid': utf8.encode(serverId),
                'v': utf8.encode('1'),
              },
            ),
          )
          .timeout(const Duration(seconds: 10));
      return true;
    } on Object catch (error) {
      debugPrint('NSD: не удалось объявить сервис: $error');
      return false;
    }
  }

  Future<void> stop() async {
    final registration = _registration;
    _registration = null;
    if (registration == null) return;
    try {
      await nsd.unregister(registration).timeout(const Duration(seconds: 5));
    } on Object catch (error) {
      debugPrint('NSD: не удалось снять объявление сервиса: $error');
    }
  }
}

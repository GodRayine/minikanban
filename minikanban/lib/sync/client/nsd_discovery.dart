/// Поиск ПК через DNS-SD (`_minikanban._tcp`) с фильтром по `sid`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:nsd/nsd.dart' as nsd;

import '../server/nsd_advertiser.dart' show nsdServiceType;
import 'sync_api.dart';

/// Реализация `ServiceDiscovery` на пакете `nsd`. На Android пакет сам
/// берёт `MulticastLock` (нужно разрешение CHANGE_WIFI_MULTICAST_STATE).
/// Любая ошибка — пустой результат: каскад поиска продолжит другими путями.
Future<List<Endpoint>> discoverMiniKanban(
  String serverId,
  Duration timeout,
) async {
  final found = <Endpoint>{};
  final done = Completer<void>();
  nsd.Discovery? discovery;
  final watch = Stopwatch()..start();

  void collect() {
    final current = discovery;
    if (current == null) return;
    for (final service in current.services) {
      final sid = service.txt?['sid'];
      final port = service.port;
      if (sid == null || port == null) continue;
      if (utf8.decode(sid, allowMalformed: true) != serverId) continue;
      for (final address in service.addresses ?? const <InternetAddress>[]) {
        found.add(Endpoint(address.address, port));
      }
      final host = service.host;
      if (host != null && host.isNotEmpty) found.add(Endpoint(host, port));
    }
    if (found.isNotEmpty && !done.isCompleted) done.complete();
  }

  try {
    discovery = await nsd
        .startDiscovery(nsdServiceType, ipLookupType: nsd.IpLookupType.v4)
        .timeout(timeout);
    discovery.addListener(collect);
    collect();
    final left = timeout - watch.elapsed;
    if (!left.isNegative) {
      await done.future.timeout(left, onTimeout: () {});
    }
  } on Object catch (error) {
    debugPrint('NSD: поиск не удался: $error');
  } finally {
    final current = discovery;
    if (current != null) {
      current.removeListener(collect);
      try {
        await nsd.stopDiscovery(current).timeout(const Duration(seconds: 2));
      } on Object catch (error) {
        debugPrint('NSD: не удалось остановить поиск: $error');
      }
    }
  }
  debugPrint(
    'NSD: найдено адресов: ${found.length}'
    '${found.isEmpty ? '' : ' (${found.join(', ')})'} '
    'за ${watch.elapsedMilliseconds} мс',
  );
  return found.toList();
}

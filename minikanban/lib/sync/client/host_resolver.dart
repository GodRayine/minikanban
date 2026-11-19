/// Поиск ПК в сети каскадом: последний удачный адрес → DNS-SD →
/// `<host>.local` → IP-кандидаты из QR. Каждый кандидат проверяется
/// через `GET /v1/hello` на совпадение `server_id`.
library;

import 'dart:async';

import '../protocol/dto.dart';
import 'sync_api.dart';

/// Проверка кандидата: `GET /v1/hello` с таймаутом.
typedef HelloProbe = Future<HelloResponse> Function(
  Endpoint endpoint,
  Duration timeout,
);

/// Поиск сервера `serverId` через DNS-SD; возвращает найденные адреса.
typedef ServiceDiscovery = Future<List<Endpoint>> Function(
  String serverId,
  Duration timeout,
);

/// Каким путём найден ПК.
enum HostSource { lastGood, nsd, hostName, qrIp }

final class ResolvedHost {
  const ResolvedHost(this.endpoint, this.hello, this.source);

  final Endpoint endpoint;
  final HelloResponse hello;
  final HostSource source;
}


class HostResolver {
  HostResolver({
    required this.probe,
    this.discover,
    this.lastGoodTimeout = const Duration(milliseconds: 1500),
    this.discoveryTimeout = const Duration(seconds: 3),
    this.probeTimeout = const Duration(milliseconds: 2500),
  });

  final HelloProbe probe;

  /// DNS-SD; `null` — этап пропускается.
  final ServiceDiscovery? discover;

  final Duration lastGoodTimeout;
  final Duration discoveryTimeout;
  final Duration probeTimeout;

  /// Ищет сервер [serverId].
  ///
  /// [ipsFirst] — сначала IP из QR (привязка: адреса только что сняты с
  /// экрана ПК), иначе они проверяются последними.
  ///
  /// Бросает [HostNotFoundException], [SyncCertException] (нашёлся адрес,
  /// но сертификат чужой) или [SyncIncompatibleException].
  Future<ResolvedHost> resolve({
    required String serverId,
    Endpoint? lastGood,
    String? hostName,
    List<String> ips = const [],
    required int port,
    bool ipsFirst = false,
  }) async {
    final tried = <Endpoint>{};
    var certMismatch = false;

    Future<ResolvedHost?> attempt(
      Iterable<Endpoint> candidates,
      HostSource source,
      Duration timeout,
    ) async {
      final fresh = [
        for (final c in candidates)
          if (tried.add(c)) c,
      ];
      if (fresh.isEmpty) return null;
      final done = Completer<ResolvedHost?>();
      var left = fresh.length;
      for (final endpoint in fresh) {
        unawaited(() async {
          try {
            final hello = await probe(endpoint, timeout);
            if (hello.serverId == serverId && !done.isCompleted) {
              done.complete(ResolvedHost(endpoint, hello, source));
            }
          } on SyncCertException {
            certMismatch = true;
          } on Object {
            // Кандидат недоступен — пробуем остальных.
          } finally {
            left--;
            if (left == 0 && !done.isCompleted) done.complete(null);
          }
        }());
      }
      return done.future;
    }

    Future<ResolvedHost?> byLastGood() async => lastGood == null
        ? null
        : attempt([lastGood], HostSource.lastGood, lastGoodTimeout);

    Future<ResolvedHost?> byNsd() async {
      final discover = this.discover;
      if (discover == null) return null;
      List<Endpoint> found;
      try {
        found = await discover(serverId, discoveryTimeout);
      } on Object {
        return null;
      }
      return attempt(found, HostSource.nsd, probeTimeout);
    }

    Future<ResolvedHost?> byHostName() async {
      final name = hostName?.trim() ?? '';
      if (name.isEmpty) return null;
      return attempt(
        [
          if (!name.contains('.')) Endpoint('$name.local', port),
          Endpoint(name, port),
        ],
        HostSource.hostName,
        probeTimeout,
      );
    }

    Future<ResolvedHost?> byIps() => attempt(
          [for (final ip in ips) Endpoint(ip, port)],
          HostSource.qrIp,
          probeTimeout,
        );

    final stages = ipsFirst
        ? [byIps, byLastGood, byNsd, byHostName]
        : [byLastGood, byNsd, byHostName, byIps];
    for (final stage in stages) {
      final found = await stage();
      if (found == null) continue;
      if (!found.hello.isCompatible) throw const SyncIncompatibleException();
      return found;
    }
    if (certMismatch) throw const SyncCertException();
    throw const HostNotFoundException();
  }
}

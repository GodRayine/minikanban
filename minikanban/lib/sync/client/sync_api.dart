/// HTTPS-клиент протокола v1 с пиннингом сертификата ПК.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../crypto_util.dart';
import '../protocol/dto.dart';

/// Адрес сервера: хост (IP или имя) и порт.
final class Endpoint {
  const Endpoint(this.host, this.port);

  /// Разбирает `host:port` или `[ipv6]:port`; без порта — [defaultPort].
  /// Возвращает `null`, если строка не похожа на адрес.
  static Endpoint? tryParse(String raw, {int? defaultPort}) {
    final text = raw.trim();
    if (text.isEmpty || text.contains(RegExp(r'[\s/?#@]'))) return null;
    String host;
    String? portText;
    final bracket = RegExp(r'^\[([0-9a-fA-F:.]+)\](?::(\d+))?$').firstMatch(text);
    if (bracket != null) {
      host = bracket.group(1)!;
      portText = bracket.group(2);
    } else {
      final colon = text.lastIndexOf(':');
      if (colon >= 0 && text.indexOf(':') == colon) {
        host = text.substring(0, colon);
        portText = text.substring(colon + 1);
      } else {
        host = text;
      }
    }
    final port = portText == null ? defaultPort : int.tryParse(portText);
    if (host.isEmpty || port == null || port < 1 || port > 65535) return null;
    return Endpoint(host, port);
  }

  final String host;
  final int port;

  Uri uri(String path) =>
      Uri(scheme: 'https', host: host, port: port, path: path);

  @override
  bool operator ==(Object other) =>
      other is Endpoint && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => host.contains(':') ? '[$host]:$port' : '$host:$port';
}

/// Базовый класс ошибок обмена с ПК.
sealed class SyncException implements Exception {
  const SyncException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// ПК недоступен: нет сети, таймаут, не тот ответ.
base class SyncNetworkException extends SyncException {
  const SyncNetworkException(super.message);
}

/// ПК не найден ни одним из способов поиска.
final class HostNotFoundException extends SyncNetworkException {
  const HostNotFoundException() : super('Компьютер не найден в сети');
}

/// Сертификат сервера не совпал с отпечатком из QR.
final class SyncCertException extends SyncException {
  const SyncCertException([
    super.message = 'Сертификат компьютера не совпал с отпечатком',
  ]);
}

/// 401: токен неизвестен ПК или отозван.
final class SyncUnauthorizedException extends SyncException {
  const SyncUnauthorizedException(this.reason)
      : super('Компьютер отклонил токен ($reason)');

  /// `revoked` или `unknown`.
  final String reason;
}

/// 410: курсор устарел, нужен полный reset.
final class SyncGoneException extends SyncException {
  const SyncGoneException() : super('Курсор устарел');
}

/// Версии протокола не совпадают.
final class SyncIncompatibleException extends SyncException {
  const SyncIncompatibleException([super.message = 'Несовместимая версия']);
}

/// ПК отклонил привязку (`invalid_code`, `expired_code`, `rate_limited`).
final class PairingRejectedException extends SyncException {
  const PairingRejectedException(this.reason)
      : super('Компьютер отклонил привязку ($reason)');

  final String reason;
}

/// Ответ `POST /v1/pair` вместе с необязательным доказательством сервера.
final class PairReply {
  const PairReply(this.response, this.serverProof);

  final PairResponse response;
  final String? serverProof;
}

/// Клиент API. Все методы бросают [SyncException].
abstract interface class SyncApi {
  /// Отпечаток сертификата, предъявленного сервером [endpoint] (после
  /// любого успешного запроса). В режиме пиннинга равен ожидаемому.
  String? seenFingerprint(Endpoint endpoint);

  Future<HelloResponse> hello(Endpoint endpoint, {required Duration timeout});

  Future<PairReply> pair(
    Endpoint endpoint,
    Map<String, Object?> body, {
    Duration timeout,
  });

  Future<SyncResponse> sync(
    Endpoint endpoint,
    String token,
    SyncRequest request, {
    Duration timeout,
  });

  void close();
}

/// Создаёт [SyncApi]: с отпечатком — строгий пиннинг, без него
/// (`null`) — режим «доверие при первом подключении» для ручного ввода
/// адреса, где отпечаток затем проверяется доказательством знания кода.
typedef SyncApiFactory = SyncApi Function(String? fingerprint);

SyncApi defaultSyncApiFactory(String? fingerprint) =>
    HttpSyncApi(fingerprint: fingerprint);

class HttpSyncApi implements SyncApi {
  HttpSyncApi({
    required this.fingerprint,
    Duration connectTimeout = const Duration(seconds: 4),
  }) : _client = HttpClient(context: SecurityContext(withTrustedRoots: false)) {
    _client
      ..connectionTimeout = connectTimeout
      ..idleTimeout = const Duration(seconds: 15)
      // Самоподписанный сертификат никогда не проходит обычную проверку,
      // поэтому решение всегда принимается здесь — по отпечатку SPKI.
      ..badCertificateCallback = _checkCertificate;
  }

  /// Ожидаемый отпечаток SPKI или `null` (принять любой и запомнить).
  final String? fingerprint;

  final HttpClient _client;
  final Map<String, String> _seen = {};
  final Set<String> _mismatched = {};

  static const Duration defaultTimeout = Duration(seconds: 20);
  static const int _maxResponseBytes = 64 * 1024 * 1024;

  static String _key(String host, int port) => '$host:$port';

  bool _checkCertificate(X509Certificate certificate, String host, int port) {
    final String actual;
    try {
      actual = spkiFingerprint(certificate.der);
    } on Object {
      _mismatched.add(_key(host, port));
      return false;
    }
    final expected = fingerprint;
    if (expected != null && !constantTimeEquals(actual, expected)) {
      _mismatched.add(_key(host, port));
      return false;
    }
    _seen[_key(host, port)] = actual;
    return true;
  }

  @override
  String? seenFingerprint(Endpoint endpoint) =>
      _seen[_key(endpoint.host, endpoint.port)];

  Future<(int, Object?)> _send(
    String method,
    Endpoint endpoint,
    String path, {
    Object? body,
    String? token,
    required Duration timeout,
  }) async {
    final key = _key(endpoint.host, endpoint.port);
    HttpClientRequest? request;
    try {
      return await () async {
        final req = await _client.openUrl(method, endpoint.uri(path));
        request = req;
        req.headers.set(HttpHeaders.acceptHeader, 'application/json');
        if (token != null) {
          req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        }
        if (body != null) {
          final bytes = utf8.encode(jsonEncode(body));
          req.headers
            ..contentType = ContentType('application', 'json', charset: 'utf-8')
            ..contentLength = bytes.length;
          req.add(bytes);
        }
        final response = await req.close();
        final builder = BytesBuilder(copy: false);
        await for (final chunk in response) {
          builder.add(chunk);
          if (builder.length > _maxResponseBytes) {
            throw const SyncNetworkException('Слишком большой ответ');
          }
        }
        Object? json;
        try {
          json = jsonDecode(utf8.decode(builder.takeBytes()));
        } on FormatException {
          json = null;
        }
        return (response.statusCode, json);
      }()
          .timeout(timeout);
    } on SyncException {
      rethrow;
    } on TimeoutException {
      request?.abort();
      throw SyncNetworkException('Нет ответа от $endpoint');
    } on TlsException catch (e) {
      // HandshakeException — тоже TlsException.
      if (_mismatched.remove(key)) throw const SyncCertException();
      throw SyncNetworkException('Ошибка TLS: ${e.message}');
    } on SocketException catch (e) {
      throw SyncNetworkException('Нет соединения с $endpoint: ${e.message}');
    } on HttpException catch (e) {
      throw SyncNetworkException('Ошибка HTTP: ${e.message}');
    } on ArgumentError catch (e) {
      throw SyncNetworkException('Некорректный адрес $endpoint: $e');
    }
  }

  static String _reason(Object? json) => switch (json) {
        {'reason': final String reason} => reason,
        _ => 'unknown',
      };

  @override
  Future<HelloResponse> hello(
    Endpoint endpoint, {
    required Duration timeout,
  }) async {
    final (status, json) =
        await _send('GET', endpoint, '/v1/hello', timeout: timeout);
    if (status != HttpStatus.ok) {
      throw SyncNetworkException('hello: неожиданный статус $status');
    }
    try {
      return HelloResponse.fromJson(json);
    } on ProtocolException catch (e) {
      throw SyncNetworkException('hello: ${e.message}');
    }
  }

  @override
  Future<PairReply> pair(
    Endpoint endpoint,
    Map<String, Object?> body, {
    Duration timeout = defaultTimeout,
  }) async {
    final (status, json) = await _send(
      'POST',
      endpoint,
      '/v1/pair',
      body: body,
      timeout: timeout,
    );
    if (status == HttpStatus.forbidden ||
        status == HttpStatus.tooManyRequests) {
      throw PairingRejectedException(_reason(json));
    }
    if (status != HttpStatus.ok) {
      throw SyncNetworkException('pair: неожиданный статус $status');
    }
    try {
      return PairReply(
        PairResponse.fromJson(json),
        switch (json) {
          {'server_proof': final String proof} => proof,
          _ => null,
        },
      );
    } on ProtocolException catch (e) {
      throw SyncNetworkException('pair: ${e.message}');
    }
  }

  @override
  Future<SyncResponse> sync(
    Endpoint endpoint,
    String token,
    SyncRequest request, {
    Duration timeout = defaultTimeout,
  }) async {
    final (status, json) = await _send(
      'POST',
      endpoint,
      '/v1/sync',
      body: request.toJson(),
      token: token,
      timeout: timeout,
    );
    switch (status) {
      case HttpStatus.ok:
        try {
          return SyncResponse.fromJson(json);
        } on ProtocolException catch (e) {
          throw SyncIncompatibleException('sync: ${e.message}');
        }
      case HttpStatus.unauthorized:
        throw SyncUnauthorizedException(_reason(json));
      case HttpStatus.gone:
        throw const SyncGoneException();
      default:
        throw SyncNetworkException('sync: неожиданный статус $status');
    }
  }

  @override
  void close() => _client.close(force: true);
}

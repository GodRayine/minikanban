/// Содержимое QR-кода привязки телефона к ПК.
///
/// Формат: `mkanban://pair?v=1&sid=&name=&h=&ip=a,b&p=&c=&fp=&exp=`.
library;

/// Причина, по которой QR не принят.
enum QrPayloadError {
  /// Это не QR MiniKanban (другая схема/действие или не URI).
  notMiniKanban,

  /// QR выпущен несовместимой версией приложения.
  unsupportedVersion,

  /// Нет обязательного параметра.
  missingField,

  /// Параметр есть, но значение некорректно.
  invalidField,

  /// Срок действия кода истёк.
  expired,
}

/// Ошибка разбора/проверки QR с сообщением для пользователя.
class QrPayloadException implements Exception {
  const QrPayloadException(this.error, this.message, {this.field});

  final QrPayloadError error;

  /// Понятное пользователю описание.
  final String message;

  /// Имя параметра QR, если ошибка относится к конкретному полю.
  final String? field;

  @override
  String toString() => 'QrPayloadException(${error.name}): $message';
}

/// Данные для привязки: кто сервер, где его искать и одноразовый код.
final class PairingQrPayload {
  const PairingQrPayload({
    required this.serverId,
    required this.serverName,
    required this.host,
    required this.port,
    required this.code,
    required this.fingerprint,
    required this.exp,
    this.ips = const [],
  });

  static const String scheme = 'mkanban';
  static const String action = 'pair';
  static const int version = 1;
  static const int defaultPort = 47321;

  static final RegExp _fingerprintPattern = RegExp(r'^[A-Za-z0-9_-]{43}=?$');

  /// `sid` — идентификатор сервера (сверяется с `/v1/hello`).
  final String serverId;

  /// `name` — отображаемое имя ПК.
  final String serverName;

  /// `h` — сетевое имя ПК (для `<host>.local` и DNS).
  final String host;

  /// `ip` — IP-кандидаты ПК на момент показа QR (может быть пустым).
  final List<String> ips;

  /// `p` — TCP-порт сервера, 1..65535.
  final int port;

  /// `c` — одноразовый код привязки.
  final String code;

  /// `fp` — SHA-256 отпечаток SPKI сертификата, base64url (43 символа).
  final String fingerprint;

  /// `exp` — срок действия кода, секунды эпохи Unix.
  final int exp;

  /// Срок действия как [DateTime] (UTC).
  DateTime get expiresAt =>
      DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);

  /// Истёк ли код к моменту [now].
  bool isExpired(DateTime now) => now.millisecondsSinceEpoch >= exp * 1000;

  /// Проверяет поля; бросает [QrPayloadException]. Срок действия здесь
  /// не проверяется — см. [isExpired] и [parse].
  void validate() {
    void require(String field, String value) {
      if (value.trim().isEmpty) {
        throw QrPayloadException(
          QrPayloadError.missingField,
          'В QR-коде нет обязательного параметра "$field"',
          field: field,
        );
      }
    }

    require('sid', serverId);
    require('name', serverName);
    require('h', host);
    require('c', code);
    require('fp', fingerprint);

    if (port < 1 || port > 65535) {
      throw _invalid('p', 'Некорректный порт в QR-коде');
    }
    if (!_fingerprintPattern.hasMatch(fingerprint)) {
      throw _invalid('fp', 'Некорректный отпечаток сертификата в QR-коде');
    }
    if (exp <= 0) {
      throw _invalid('exp', 'Некорректный срок действия в QR-коде');
    }
    for (final ip in ips) {
      if (!_isIpAddress(ip)) {
        throw _invalid('ip', 'Некорректный IP-адрес в QR-коде: "$ip"');
      }
    }
  }

  /// Кодирует в строку для QR. Перед кодированием вызывает [validate].
  String encode() {
    validate();
    String q(String s) => Uri.encodeQueryComponent(s);
    return '$scheme://$action'
        '?v=$version'
        '&sid=${q(serverId)}'
        '&name=${q(serverName)}'
        '&h=${q(host)}'
        '&ip=${ips.map(q).join(',')}'
        '&p=$port'
        '&c=${q(code)}'
        '&fp=${q(fingerprint)}'
        '&exp=$exp';
  }

  /// Разбирает строку из QR и проверяет её.
  ///
  /// [now] — текущее время (по умолчанию системное); если код просрочен,
  /// бросается [QrPayloadException] с [QrPayloadError.expired].
  static PairingQrPayload parse(String raw, {DateTime? now}) {
    final Uri uri;
    try {
      uri = Uri.parse(raw.trim());
    } on FormatException {
      throw _notOurs();
    }
    if (uri.scheme != scheme || uri.host != action) throw _notOurs();

    final Map<String, String> params;
    try {
      params = uri.queryParameters;
    } on Object {
      // Битое percent-кодирование и т.п.
      throw _notOurs();
    }

    String require(String field) {
      final value = params[field];
      if (value == null || value.trim().isEmpty) {
        throw QrPayloadException(
          QrPayloadError.missingField,
          'В QR-коде нет обязательного параметра "$field"',
          field: field,
        );
      }
      return value;
    }

    int requireInt(String field, String message) =>
        int.tryParse(require(field)) ?? (throw _invalid(field, message));

    final v = requireInt('v', 'Некорректная версия QR-кода');
    if (v != version) {
      throw QrPayloadException(
        QrPayloadError.unsupportedVersion,
        'QR-код создан несовместимой версией приложения (v=$v). '
        'Обновите MiniKanban на обоих устройствах',
        field: 'v',
      );
    }

    final payload = PairingQrPayload(
      serverId: require('sid'),
      serverName: require('name'),
      host: require('h'),
      ips: List.unmodifiable(
        (params['ip'] ?? '')
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty),
      ),
      port: requireInt('p', 'Некорректный порт в QR-коде'),
      code: require('c'),
      fingerprint: require('fp'),
      exp: requireInt('exp', 'Некорректный срок действия в QR-коде'),
    )..validate();

    if (payload.isExpired(now ?? DateTime.now())) {
      throw const QrPayloadException(
        QrPayloadError.expired,
        'Срок действия QR-кода истёк. Обновите код на компьютере',
        field: 'exp',
      );
    }
    return payload;
  }

  static QrPayloadException _notOurs() => const QrPayloadException(
        QrPayloadError.notMiniKanban,
        'Это не QR-код MiniKanban',
      );

  static QrPayloadException _invalid(String field, String message) =>
      QrPayloadException(QrPayloadError.invalidField, message, field: field);

  static bool _isIpAddress(String value) {
    try {
      Uri.parseIPv4Address(value);
      return true;
    } on FormatException {
      // не IPv4 — пробуем IPv6
    }
    try {
      Uri.parseIPv6Address(value);
      return true;
    } on FormatException {
      return false;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PairingQrPayload &&
      other.serverId == serverId &&
      other.serverName == serverName &&
      other.host == host &&
      other.port == port &&
      other.code == code &&
      other.fingerprint == fingerprint &&
      other.exp == exp &&
      other.ips.length == ips.length &&
      Iterable<int>.generate(ips.length).every((i) => other.ips[i] == ips[i]);

  @override
  int get hashCode => Object.hash(
        serverId,
        serverName,
        host,
        port,
        code,
        fingerprint,
        exp,
        Object.hashAll(ips),
      );

  @override
  String toString() =>
      'PairingQrPayload($serverName, $host:$port, ips=$ips, exp=$exp)';
}

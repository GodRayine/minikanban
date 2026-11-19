/// Привязка телефонов на ПК: одноразовые коды, токены устройств, отзыв.
library;

import 'dart:math';

import 'package:sqflite_common/sqlite_api.dart';

import '../../data/device_dao.dart';
import '../crypto_util.dart';

/// Одноразовый код привязки (показывается в QR).
final class PairingCode {
  const PairingCode({required this.code, required this.expiresAt});

  /// 128 бит в base64url (22 символа).
  final String code;
  final DateTime expiresAt;

  /// Срок действия в секундах эпохи Unix (параметр `exp` в QR).
  int get exp => expiresAt.millisecondsSinceEpoch ~/ 1000;
}

/// Почему привязка отклонена.
enum PairingFailure {
  /// Код неверный, уже использован или не выпускался.
  invalid,

  /// Срок действия кода истёк.
  expired,

  /// Слишком много попыток за минуту.
  rateLimited;

  /// Значение поля `reason` в ответе сервера.
  String get wire => switch (this) {
        invalid => 'invalid_code',
        expired => 'expired_code',
        rateLimited => 'rate_limited',
      };
}

/// Итог [PairingService.pair].
final class PairingResult {
  const PairingResult.success({
    required String this.deviceToken,
    this.serverProof,
  }) : failure = null;

  const PairingResult.failed(PairingFailure this.failure)
      : deviceToken = null,
        serverProof = null;

  /// Токен устройства (256 бит, base64url) — отдаётся телефону один раз.
  final String? deviceToken;

  /// Ответное доказательство знания кода (только при привязке по
  /// доказательству, см. [pairingServerProofFromHash]).
  final String? serverProof;
  final PairingFailure? failure;

  bool get ok => failure == null;
}

/// Итог проверки Bearer-токена.
enum TokenStatus { ok, unknown, revoked }

class PairingService {
  PairingService(
    this._db, {
    DateTime Function()? now,
    Random? random,
    this.codeTtl = const Duration(minutes: 5),
    this.maxAttemptsPerMinute = 5,
  })  : _now = now ?? DateTime.now,
        _random = random;

  final Database _db;
  final DateTime Function() _now;
  final Random? _random;

  /// Сколько действует код.
  final Duration codeTtl;

  /// Лимит попыток привязки за скользящую минуту (успешных и нет).
  final int maxAttemptsPerMinute;

  /// Хэш действующего кода: сам код сервис не хранит.
  String? _codeHash;
  DateTime? _codeExpiresAt;
  final List<DateTime> _attempts = [];

  /// Выпускает новый код; прежний перестаёт действовать.
  PairingCode newCode() {
    final code = randomSecret(16, random: _random);
    final expiresAt = _now().add(codeTtl);
    _codeHash = sha256Hex(code);
    _codeExpiresAt = expiresAt;
    return PairingCode(code: code, expiresAt: expiresAt);
  }

  /// Гасит действующий код (экран подключения закрыт).
  void cancelCode() {
    _codeHash = null;
    _codeExpiresAt = null;
  }

  /// Есть ли действующий (не использованный и не просроченный) код.
  bool get hasActiveCode {
    final expiresAt = _codeExpiresAt;
    return _codeHash != null &&
        expiresAt != null &&
        _now().isBefore(expiresAt);
  }

  /// Привязывает устройство по коду [code] либо по доказательству
  /// [proof] (HMAC от кода и [fingerprint] сертификата — ручной ввод
  /// адреса на телефоне). Код одноразовый: после успеха он гасится.
  Future<PairingResult> pair({
    String? code,
    String? proof,
    String? fingerprint,
    required String deviceId,
    required String deviceName,
    required String platform,
  }) async {
    final now = _now();
    _attempts.removeWhere(
      (t) => now.difference(t) >= const Duration(minutes: 1),
    );
    if (_attempts.length >= maxAttemptsPerMinute) {
      return const PairingResult.failed(PairingFailure.rateLimited);
    }
    _attempts.add(now);

    final codeHash = _codeHash;
    final expiresAt = _codeExpiresAt;
    if (codeHash == null || expiresAt == null) {
      return const PairingResult.failed(PairingFailure.invalid);
    }

    final bool matches;
    if (code != null) {
      matches = constantTimeEquals(sha256Hex(code), codeHash);
    } else if (proof != null && fingerprint != null) {
      matches = constantTimeEquals(
        proof,
        pairingClientProofFromHash(
          codeHash: codeHash,
          fingerprint: fingerprint,
          deviceId: deviceId,
        ),
      );
    } else {
      matches = false;
    }
    if (!matches) return const PairingResult.failed(PairingFailure.invalid);
    if (!now.isBefore(expiresAt)) {
      return const PairingResult.failed(PairingFailure.expired);
    }

    // Код одноразовый.
    _codeHash = null;
    _codeExpiresAt = null;

    final token = randomSecret(32, random: _random);
    await DeviceDao(_db).upsert(
      PairedDevice(
        deviceId: deviceId,
        name: deviceName,
        platform: platform,
        tokenHash: sha256Hex(token),
        pairedAt: now.millisecondsSinceEpoch,
      ),
    );
    return PairingResult.success(
      deviceToken: token,
      serverProof: code != null || fingerprint == null
          ? null
          : pairingServerProofFromHash(
              codeHash: codeHash,
              fingerprint: fingerprint,
              deviceId: deviceId,
            ),
    );
  }

  /// Проверяет Bearer-токен: возвращает устройство и его статус.
  Future<(TokenStatus, PairedDevice?)> authenticate(String? token) async {
    if (token == null || token.isEmpty) return (TokenStatus.unknown, null);
    final device = await DeviceDao(_db).getByTokenHash(sha256Hex(token));
    if (device == null) return (TokenStatus.unknown, null);
    return (device.revoked ? TokenStatus.revoked : TokenStatus.ok, device);
  }

  /// Отвязывает устройство: его токен начинает получать 401 `revoked`.
  Future<void> revoke(String deviceId) => DeviceDao(_db).revoke(deviceId);

  /// Привязанные (не отозванные) устройства, новые сверху.
  Future<List<PairedDevice>> devices() => DeviceDao(_db).active();
}

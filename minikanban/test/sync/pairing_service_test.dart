import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:minikanban/data/db.dart';
import 'package:minikanban/data/device_dao.dart';
import 'package:minikanban/sync/crypto_util.dart';
import 'package:minikanban/sync/server/cert_service.dart';
import 'package:minikanban/sync/server/pairing_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Database db;
  late DateTime now;
  late PairingService service;

  setUp(() async {
    db = await openAppDatabase(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    now = DateTime(2026, 11, 19, 12);
    service = PairingService(db, now: () => now);
  });

  tearDown(() => db.close());

  Future<PairingResult> pair(String? code, {String deviceId = 'phone-1'}) =>
      service.pair(
        code: code,
        deviceId: deviceId,
        deviceName: 'Pixel 9',
        platform: 'android',
      );

  test('код — 128 бит в base64url, действует 5 минут', () {
    final code = service.newCode();
    expect(code.code, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
    expect(base64Url.decode('${code.code}=='), hasLength(16));
    expect(code.expiresAt, now.add(const Duration(minutes: 5)));
    expect(code.exp, code.expiresAt.millisecondsSinceEpoch ~/ 1000);
    expect(service.hasActiveCode, isTrue);
    expect(service.newCode().code, isNot(code.code));
  });

  test('успешная привязка выдаёт токен 256 бит; в БД только хэш', () async {
    final code = service.newCode();
    final result = await pair(code.code);

    expect(result.ok, isTrue);
    final token = result.deviceToken!;
    expect(token, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    expect(base64Url.decode('$token='), hasLength(32));

    final device = (await DeviceDao(db).all()).single;
    expect(device.deviceId, 'phone-1');
    expect(device.name, 'Pixel 9');
    expect(device.platform, 'android');
    expect(device.tokenHash, sha256Hex(token));
    expect(device.pairedAt, now.millisecondsSinceEpoch);
    expect(device.revoked, isFalse);

    final raw = await db.query('devices');
    expect(raw.toString(), isNot(contains(token)));
  });

  test('код одноразовый', () async {
    final code = service.newCode();
    expect((await pair(code.code)).ok, isTrue);
    expect(service.hasActiveCode, isFalse);

    final again = await pair(code.code, deviceId: 'phone-2');
    expect(again.failure, PairingFailure.invalid);
    expect(await DeviceDao(db).all(), hasLength(1));
  });

  test('новый код отменяет прежний', () async {
    final old = service.newCode();
    final fresh = service.newCode();
    expect((await pair(old.code)).failure, PairingFailure.invalid);
    expect((await pair(fresh.code)).ok, isTrue);
  });

  test('без выпущенного кода и после отмены — отказ', () async {
    expect((await pair('anything')).failure, PairingFailure.invalid);
    final code = service.newCode();
    service.cancelCode();
    expect(service.hasActiveCode, isFalse);
    expect((await pair(code.code)).failure, PairingFailure.invalid);
  });

  test('код истекает ровно через 5 минут', () async {
    final code = service.newCode();
    now = now.add(const Duration(minutes: 4, seconds: 59));
    expect(service.hasActiveCode, isTrue);
    now = now.add(const Duration(seconds: 1));
    expect(service.hasActiveCode, isFalse);
    expect((await pair(code.code)).failure, PairingFailure.expired);
    expect(await DeviceDao(db).all(), isEmpty);
  });

  test('не больше 5 попыток в минуту', () async {
    final code = service.newCode();
    for (var i = 0; i < 5; i++) {
      expect((await pair('wrong-$i')).failure, PairingFailure.invalid);
      now = now.add(const Duration(seconds: 1));
    }
    expect((await pair(code.code)).failure, PairingFailure.rateLimited);
    // Отклонённые по лимиту попытки сами лимит не продлевают.
    now = now.add(const Duration(seconds: 56));
    expect((await pair(code.code)).ok, isTrue);
  });

  test('привязка по доказательству знания кода', () async {
    const fp = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    final code = service.newCode();

    // Доказательство для чужого сертификата (посредник) не подходит.
    final forged = await service.pair(
      proof: pairingClientProof(
        code: code.code,
        fingerprint: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
        deviceId: 'phone-1',
      ),
      fingerprint: fp,
      deviceId: 'phone-1',
      deviceName: 'Pixel 9',
      platform: 'android',
    );
    expect(forged.failure, PairingFailure.invalid);
    expect(service.hasActiveCode, isTrue);

    final result = await service.pair(
      proof: pairingClientProof(
        code: code.code,
        fingerprint: fp,
        deviceId: 'phone-1',
      ),
      fingerprint: fp,
      deviceId: 'phone-1',
      deviceName: 'Pixel 9',
      platform: 'android',
    );
    expect(result.ok, isTrue);
    expect(
      result.serverProof,
      pairingServerProofFromHash(
        codeHash: sha256Hex(code.code),
        fingerprint: fp,
        deviceId: 'phone-1',
      ),
    );
    expect(result.serverProof, isNot(forged.serverProof));
  });

  test('проверка токена и отзыв', () async {
    final token = (await pair(service.newCode().code)).deviceToken!;

    var (status, device) = await service.authenticate(token);
    expect(status, TokenStatus.ok);
    expect(device!.deviceId, 'phone-1');

    expect((await service.authenticate(null)).$1, TokenStatus.unknown);
    expect((await service.authenticate('')).$1, TokenStatus.unknown);
    expect((await service.authenticate('чужой')).$1, TokenStatus.unknown);

    await service.revoke('phone-1');
    (status, device) = await service.authenticate(token);
    expect(status, TokenStatus.revoked);
    expect(await service.devices(), isEmpty);
    expect(await DeviceDao(db).all(), hasLength(1));
  });

  test('повторная привязка того же устройства заменяет токен', () async {
    final first = (await pair(service.newCode().code)).deviceToken!;
    await service.revoke('phone-1');
    final second = (await pair(service.newCode().code)).deviceToken!;

    expect(second, isNot(first));
    expect((await service.authenticate(first)).$1, TokenStatus.unknown);
    expect((await service.authenticate(second)).$1, TokenStatus.ok);
    expect(await service.devices(), hasLength(1));
  });

  group('отпечаток сертификата', () {
    test('считается от SPKI и не зависит от остального сертификата', () {
      final identity = CertService.generate();
      final der = certificateDerFromPem(identity.certificatePem);
      final spki = spkiFromCertificateDer(der);

      // SubjectPublicKeyInfo ключа P-256: SEQUENCE длиной 89 байт.
      expect(spki.first, 0x30);
      expect(spki, hasLength(91));
      expect(identity.fingerprint, hasLength(43));
      expect(spkiFingerprint(der), identity.fingerprint);
      expect(
        CertService.generate().fingerprint,
        isNot(identity.fingerprint),
      );
    });

    test('мусор вместо сертификата — понятная ошибка', () {
      expect(
        () => spkiFingerprint(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<CertificateFormatException>()),
      );
      expect(
        () => certificateDerFromPem('не PEM'),
        throwsA(isA<CertificateFormatException>()),
      );
    });

    test('сравнение строк за постоянное время', () {
      expect(constantTimeEquals('abc', 'abc'), isTrue);
      expect(constantTimeEquals('abc', 'abd'), isFalse);
      expect(constantTimeEquals('abc', 'abcd'), isFalse);
    });
  });
}

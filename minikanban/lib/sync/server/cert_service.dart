/// Самоподписанный сертификат ПК для HTTPS-сервера синхронизации.
library;

import 'dart:convert';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:path/path.dart' as p;

import '../crypto_util.dart';

/// Сертификат, закрытый ключ и отпечаток, который телефон получает из QR.
final class ServerIdentity {
  ServerIdentity({required this.certificatePem, required this.privateKeyPem})
      : fingerprint = spkiFingerprint(certificateDerFromPem(certificatePem));

  final String certificatePem;
  final String privateKeyPem;

  /// SHA-256 от SPKI, base64url, 43 символа.
  final String fingerprint;

  /// Контекст TLS для `HttpServer.bindSecure`. Бросает [TlsException],
  /// если сертификат или ключ повреждены.
  SecurityContext securityContext() => SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(certificatePem))
    ..usePrivateKeyBytes(utf8.encode(privateKeyPem));
}

/// Создаёт сертификат при первом запуске и хранит его в каталоге данных
/// приложения. Пока файлы целы, отпечаток не меняется и телефоны остаются
/// привязанными.
class CertService {
  const CertService(this.directory);

  /// Каталог данных приложения.
  final Directory directory;

  static const String certFileName = 'server_cert.pem';
  static const String keyFileName = 'server_key.pem';

  /// Срок действия: ~20 лет. Телефон проверяет только отпечаток ключа,
  /// поэтому перевыпуск по сроку не нужен.
  static const int validityDays = 7300;

  File get _certFile => File(p.join(directory.path, certFileName));
  File get _keyFile => File(p.join(directory.path, keyFileName));

  /// Загружает сохранённый сертификат или создаёт новый.
  Future<ServerIdentity> loadOrCreate() async {
    final existing = await _load();
    if (existing != null) return existing;
    final identity = generate();
    await directory.create(recursive: true);
    await _keyFile.writeAsString(identity.privateKeyPem, flush: true);
    await _certFile.writeAsString(identity.certificatePem, flush: true);
    return identity;
  }

  Future<ServerIdentity?> _load() async {
    try {
      if (!_certFile.existsSync() || !_keyFile.existsSync()) return null;
      final identity = ServerIdentity(
        certificatePem: await _certFile.readAsString(),
        privateKeyPem: await _keyFile.readAsString(),
      );
      // Проверяем, что TLS-стек принимает пару; иначе выпускаем заново.
      identity.securityContext();
      return identity;
    } on Object {
      return null;
    }
  }

  /// Новая пара ECDSA P-256 и самоподписанный сертификат.
  static ServerIdentity generate() {
    final pair = CryptoUtils.generateEcKeyPair();
    final privateKey = pair.privateKey as ECPrivateKey;
    final publicKey = pair.publicKey as ECPublicKey;
    final csr = X509Utils.generateEccCsrPem(
      {'CN': 'MiniKanban'},
      privateKey,
      publicKey,
    );
    final serial = randomBytes(8)
        .fold<BigInt>(BigInt.one, (acc, b) => (acc << 8) | BigInt.from(b));
    final certificate = X509Utils.generateSelfSignedCertificate(
      privateKey,
      csr,
      validityDays,
      sans: const ['minikanban.local'],
      serialNumber: serial.toString(),
      notBefore: DateTime.now().toUtc().subtract(const Duration(days: 1)),
    );
    return ServerIdentity(
      certificatePem: certificate,
      privateKeyPem: CryptoUtils.encodeEcPrivateKeyToPem(privateKey),
    );
  }
}

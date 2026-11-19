/// Мелкая криптография синхронизации: случайные секреты, хэши, отпечаток
/// SPKI сертификата и «доказательство знания кода» для ручной привязки.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

final Random _secureRandom = Random.secure();

/// [bytes] криптографически случайных байт.
Uint8List randomBytes(int bytes, {Random? random}) {
  final rnd = random ?? _secureRandom;
  final out = Uint8List(bytes);
  for (var i = 0; i < bytes; i++) {
    out[i] = rnd.nextInt(256);
  }
  return out;
}

/// Base64url без `=` в конце.
String base64UrlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// Случайный секрет из [bytes] байт в base64url (16 байт → 22 символа,
/// 32 байта → 43 символа).
String randomSecret(int bytes, {Random? random}) =>
    base64UrlNoPad(randomBytes(bytes, random: random));

/// SHA-256 строки в hex — так на ПК хранятся токены и коды привязки.
String sha256Hex(String value) => sha256.convert(utf8.encode(value)).toString();

/// Сравнение строк за время, не зависящее от места первого отличия.
bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

/// Сертификат не удалось разобрать.
class CertificateFormatException implements Exception {
  const CertificateFormatException(this.message);

  final String message;

  @override
  String toString() => 'CertificateFormatException: $message';
}

/// Один элемент DER: тег и границы содержимого.
final class _Tlv {
  const _Tlv(this.tag, this.start, this.contentStart, this.end);

  final int tag;

  /// Начало элемента (байт тега).
  final int start;
  final int contentStart;

  /// Позиция сразу за элементом.
  final int end;
}

_Tlv _readTlv(Uint8List der, int offset, int limit) {
  if (offset + 2 > limit) {
    throw const CertificateFormatException('обрыв данных DER');
  }
  final tag = der[offset];
  var pos = offset + 1;
  var length = der[pos++];
  if (length & 0x80 != 0) {
    final count = length & 0x7f;
    if (count == 0 || count > 4 || pos + count > limit) {
      throw const CertificateFormatException('некорректная длина DER');
    }
    length = 0;
    for (var i = 0; i < count; i++) {
      length = (length << 8) | der[pos++];
    }
  }
  if (pos + length > limit) {
    throw const CertificateFormatException('длина DER выходит за границы');
  }
  return _Tlv(tag, offset, pos, pos + length);
}

/// DER-кодировка `SubjectPublicKeyInfo` из DER-сертификата X.509.
///
/// `Certificate ::= SEQUENCE { tbsCertificate SEQUENCE { [0] version?,
/// serial, signature, issuer, validity, subject, subjectPublicKeyInfo, … } … }`
Uint8List spkiFromCertificateDer(Uint8List der) {
  const sequence = 0x30;
  final cert = _readTlv(der, 0, der.length);
  if (cert.tag != sequence) {
    throw const CertificateFormatException('это не сертификат X.509');
  }
  final tbs = _readTlv(der, cert.contentStart, cert.end);
  if (tbs.tag != sequence) {
    throw const CertificateFormatException('нет tbsCertificate');
  }
  var pos = tbs.contentStart;
  var item = _readTlv(der, pos, tbs.end);
  if (item.tag == 0xA0) {
    // Необязательная версия.
    pos = item.end;
  }
  // serial, signature, issuer, validity, subject
  for (var i = 0; i < 5; i++) {
    item = _readTlv(der, pos, tbs.end);
    pos = item.end;
  }
  final spki = _readTlv(der, pos, tbs.end);
  if (spki.tag != sequence) {
    throw const CertificateFormatException('нет subjectPublicKeyInfo');
  }
  return Uint8List.sublistView(der, spki.start, spki.end);
}

/// Отпечаток сертификата: SHA-256 от SPKI в base64url без `=`
/// (43 символа). Именно он попадает в QR и «пиннится» телефоном.
String spkiFingerprint(Uint8List certificateDer) =>
    base64UrlNoPad(sha256.convert(spkiFromCertificateDer(certificateDer)).bytes);

/// DER-байты первого сертификата из PEM.
Uint8List certificateDerFromPem(String pem) {
  final match = RegExp(
    r'-----BEGIN CERTIFICATE-----([A-Za-z0-9+/=\s]+)-----END CERTIFICATE-----',
  ).firstMatch(pem);
  if (match == null) {
    throw const CertificateFormatException('в PEM нет сертификата');
  }
  return base64.decode(match.group(1)!.replaceAll(RegExp(r'\s'), ''));
}

String _hmac(String keyHex, String message) =>
    Hmac(sha256, utf8.encode(keyHex)).convert(utf8.encode(message)).toString();

/// Доказательство знания кода привязки, привязанное к сертификату,
/// который видит телефон (ручной ввод адреса, когда отпечатка из QR нет).
///
/// Посредник с чужим сертификатом получит доказательство для *своего*
/// отпечатка — ПК его отвергнет, а сам код по сети не передаётся.
String pairingClientProof({
  required String code,
  required String fingerprint,
  required String deviceId,
}) =>
    _hmac(sha256Hex(code), 'client|$fingerprint|$deviceId');

/// То же, но по уже посчитанному хэшу кода (на ПК хранится только хэш).
String pairingClientProofFromHash({
  required String codeHash,
  required String fingerprint,
  required String deviceId,
}) =>
    _hmac(codeHash, 'client|$fingerprint|$deviceId');

/// Ответное доказательство ПК: телефон убеждается, что сервер с этим
/// сертификатом действительно знает код.
String pairingServerProofFromHash({
  required String codeHash,
  required String fingerprint,
  required String deviceId,
}) =>
    _hmac(codeHash, 'server|$fingerprint|$deviceId');

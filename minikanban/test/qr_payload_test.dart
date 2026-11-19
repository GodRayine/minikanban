import 'package:flutter_test/flutter_test.dart';
import 'package:minikanban/sync/protocol/qr_payload.dart';

const fp = '0123456789abcdefghijklmnopqrstuvwxyzABCDE-_'; // 43 символа
const exp = 1800000000;

const payload = PairingQrPayload(
  serverId: 'srv-1',
  serverName: 'DESKTOP-01',
  host: 'desktop-01',
  ips: ['192.168.1.10', '10.0.0.5'],
  port: 47321,
  code: 'ABC123',
  fingerprint: fp,
  exp: exp,
);

const encoded = 'mkanban://pair?v=1&sid=srv-1&name=DESKTOP-01&h=desktop-01'
    '&ip=192.168.1.10,10.0.0.5&p=47321&c=ABC123&fp=$fp&exp=$exp';

final beforeExpiry =
    DateTime.fromMillisecondsSinceEpoch((exp - 60) * 1000, isUtc: true);

Matcher throwsQr(QrPayloadError error, {String? field}) {
  var matcher =
      isA<QrPayloadException>().having((e) => e.error, 'error', error);
  if (field != null) {
    matcher = matcher.having((e) => e.field, 'field', field);
  }
  return throwsA(matcher);
}

void main() {
  test('длина тестового отпечатка', () {
    expect(fp.length, 43);
  });

  group('encode', () {
    test('формат строки', () {
      expect(payload.encode(), encoded);
    });

    test('roundtrip', () {
      expect(
          PairingQrPayload.parse(payload.encode(), now: beforeExpiry), payload);
    });

    test('roundtrip с кириллицей, пробелами, спецсимволами и IPv6', () {
      const tricky = PairingQrPayload(
        serverId: 'b1946ac9-2f3d-4c5e-8a7b-0123456789ab',
        serverName: 'ПК Игоря & Co = 100%',
        host: 'игорь-пк',
        ips: ['192.168.0.2', 'fe80::1'],
        port: 1,
        code: 'a+b/c d',
        fingerprint: fp,
        exp: exp,
      );
      final parsed = PairingQrPayload.parse(tricky.encode(), now: beforeExpiry);
      expect(parsed, tricky);
      expect(parsed.serverName, 'ПК Игоря & Co = 100%');
      expect(parsed.code, 'a+b/c d');
      expect(parsed.ips, ['192.168.0.2', 'fe80::1']);
    });

    test('без IP-кандидатов', () {
      const noIps = PairingQrPayload(
        serverId: 's',
        serverName: 'n',
        host: 'h',
        port: 65535,
        code: 'c',
        fingerprint: fp,
        exp: exp,
      );
      final parsed = PairingQrPayload.parse(noIps.encode(), now: beforeExpiry);
      expect(parsed.ips, isEmpty);
      expect(parsed, noIps);
    });

    test('encode проверяет поля', () {
      PairingQrPayload make({int port = 47321, String fingerprint = fp}) =>
          PairingQrPayload(
            serverId: 's',
            serverName: 'n',
            host: 'h',
            port: port,
            code: 'c',
            fingerprint: fingerprint,
            exp: exp,
          );
      expect(() => make(port: 0).encode(),
          throwsQr(QrPayloadError.invalidField, field: 'p'));
      expect(() => make(port: 65536).encode(),
          throwsQr(QrPayloadError.invalidField, field: 'p'));
      expect(() => make(fingerprint: 'short').encode(),
          throwsQr(QrPayloadError.invalidField, field: 'fp'));
    });
  });

  group('parse', () {
    test('разбирает эталонную строку', () {
      final p = PairingQrPayload.parse(encoded, now: beforeExpiry);
      expect(p.serverId, 'srv-1');
      expect(p.serverName, 'DESKTOP-01');
      expect(p.host, 'desktop-01');
      expect(p.ips, ['192.168.1.10', '10.0.0.5']);
      expect(p.port, 47321);
      expect(p.code, 'ABC123');
      expect(p.fingerprint, fp);
      expect(p.exp, exp);
      expect(p.expiresAt,
          DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true));
    });

    test('допускает пробелы по краям', () {
      expect(
          PairingQrPayload.parse('  $encoded\n', now: beforeExpiry), payload);
    });

    test('чужие QR', () {
      for (final raw in [
        'https://example.com/?v=1',
        'mkanban://other?v=1',
        'WIFI:S:home;T:WPA;P:secret;;',
        'просто текст',
        '',
      ]) {
        expect(
          () => PairingQrPayload.parse(raw, now: beforeExpiry),
          throwsQr(QrPayloadError.notMiniKanban),
          reason: raw,
        );
      }
    });

    test('несовместимая версия', () {
      expect(
        () => PairingQrPayload.parse(
          encoded.replaceFirst('v=1', 'v=2'),
          now: beforeExpiry,
        ),
        throwsQr(QrPayloadError.unsupportedVersion, field: 'v'),
      );
    });

    test('нет обязательных параметров', () {
      final cuts = {
        'v': 'v=1&',
        'sid': '&sid=srv-1',
        'name': '&name=DESKTOP-01',
        'h': '&h=desktop-01',
        'p': '&p=47321',
        'c': '&c=ABC123',
        'fp': '&fp=$fp',
        'exp': '&exp=$exp',
      };
      for (final MapEntry(key: field, value: part) in cuts.entries) {
        expect(encoded.contains(part), isTrue, reason: part);
        expect(
          () => PairingQrPayload.parse(
            encoded.replaceFirst(part, ''),
            now: beforeExpiry,
          ),
          throwsQr(QrPayloadError.missingField, field: field),
          reason: field,
        );
      }
      // Пустое значение — тоже «нет».
      expect(
        () => PairingQrPayload.parse(
          encoded.replaceFirst('&c=ABC123', '&c='),
          now: beforeExpiry,
        ),
        throwsQr(QrPayloadError.missingField, field: 'c'),
      );
    });

    test('некорректные значения', () {
      final cases = {
        '&p=0': 'p',
        '&p=65536': 'p',
        '&p=-1': 'p',
        '&p=abc': 'p',
        '&exp=soon': 'exp',
        '&fp=tooshort': 'fp',
        '&ip=192.168.1.10,not-an-ip': 'ip',
      };
      final originals = {
        'p': '&p=47321',
        'exp': '&exp=$exp',
        'fp': '&fp=$fp',
        'ip': '&ip=192.168.1.10,10.0.0.5',
      };
      for (final MapEntry(key: replacement, value: field) in cases.entries) {
        expect(
          () => PairingQrPayload.parse(
            encoded.replaceFirst(originals[field]!, replacement),
            now: beforeExpiry,
          ),
          throwsQr(QrPayloadError.invalidField, field: field),
          reason: replacement,
        );
      }
    });

    test('срок действия', () {
      final atExpiry =
          DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
      final lastMoment = atExpiry.subtract(const Duration(milliseconds: 1));
      expect(PairingQrPayload.parse(encoded, now: lastMoment), payload);
      expect(
        () => PairingQrPayload.parse(encoded, now: atExpiry),
        throwsQr(QrPayloadError.expired),
      );
      expect(payload.isExpired(lastMoment), isFalse);
      expect(payload.isExpired(atExpiry), isTrue);
    });

    test('сообщения об ошибках понятны пользователю', () {
      try {
        PairingQrPayload.parse(encoded, now: DateTime.utc(2100));
        fail('ожидалось исключение');
      } on QrPayloadException catch (e) {
        expect(e.message, contains('истёк'));
      }
    });
  });
}

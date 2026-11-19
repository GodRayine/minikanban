import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:minikanban/core/hlc.dart';
import 'package:minikanban/sync/protocol/dto.dart';

/// Прогон через настоящий JSON-текст, как при передаче по сети.
Object? wire(Object? json) => jsonDecode(jsonEncode(json));

final Matcher throwsProtocol = throwsA(isA<ProtocolException>());

const h1 = Hlc(1700000000000, 0, 'pc');
const h2 = Hlc(1700000000500, 3, 'phone-1');

const fullChange = CardChange(
  changeId: 'ch-1',
  id: 'card-1',
  fields: {
    'title': 'Купить молоко',
    'description': 'И хлеб\nвторой строкой',
    'column': 1,
    'pos': 'a0V',
    'deleted': false,
    'created_at': 1700000000000,
  },
  hlc: {
    'title': h1,
    'description': h1,
    'column': h2,
    'pos': h2,
    'deleted': h1,
  },
);

const partialChange = CardChange(
  changeId: 'ch-2',
  id: 'card-2',
  fields: {'deleted': true},
  hlc: {'deleted': h2},
);

Map<String, Object?> validChangeJson() => fullChange.toJson();

void main() {
  test('protocolVersion == 1', () {
    expect(protocolVersion, 1);
  });

  group('CardChange', () {
    test('toJson — формат протокола', () {
      expect(partialChange.toJson(), {
        'change_id': 'ch-2',
        'entity': 'card',
        'id': 'card-2',
        'fields': {'deleted': true},
        'hlc': {'deleted': '001700000000500:0003:phone-1'},
      });
    });

    test('roundtrip', () {
      for (final c in [fullChange, partialChange]) {
        final back = CardChange.fromJson(wire(c.toJson()));
        expect(back, c);
        expect(back.hashCode, c.hashCode);
        expect(back.toJson(), c.toJson());
      }
      expect(fullChange.createdAt, 1700000000000);
      expect(partialChange.createdAt, isNull);
    });

    test('== различает содержимое', () {
      final other = CardChange.fromJson(
        wire(validChangeJson()..['change_id'] = 'другой'),
      );
      expect(other == fullChange, isFalse);
    });

    test('отвергает некорректный формат', () {
      Map<String, Object?> mutate(void Function(Map<String, Object?> j) f) {
        final j = wire(validChangeJson()) as Map<String, Object?>;
        f(j);
        return j;
      }

      Map<String, Object?> fieldsOf(Map<String, Object?> j) =>
          j['fields'] as Map<String, Object?>;
      Map<String, Object?> hlcOf(Map<String, Object?> j) =>
          j['hlc'] as Map<String, Object?>;

      final bad = <String, Object?>{
        'не объект': 'строка',
        'массив': <Object?>[],
        'null': null,
        'нет change_id': mutate((j) => j.remove('change_id')),
        'пустой change_id': mutate((j) => j['change_id'] = ''),
        'нет id': mutate((j) => j.remove('id')),
        'чужая сущность': mutate((j) => j['entity'] = 'board'),
        'нет entity': mutate((j) => j.remove('entity')),
        'fields не объект': mutate((j) => j['fields'] = 5),
        'нет hlc': mutate((j) => j.remove('hlc')),
        'неизвестное поле': mutate((j) => fieldsOf(j)['color'] = 'red'),
        'title не строка': mutate((j) => fieldsOf(j)['title'] = 5),
        'пустой title': mutate((j) => fieldsOf(j)['title'] = '   '),
        'длинный title': mutate((j) => fieldsOf(j)['title'] = 'я' * 121),
        'длинное описание':
            mutate((j) => fieldsOf(j)['description'] = 'x' * 2001),
        'column вне диапазона': mutate((j) => fieldsOf(j)['column'] = 3),
        'column строкой': mutate((j) => fieldsOf(j)['column'] = '1'),
        'pos некорректен': mutate((j) => fieldsOf(j)['pos'] = 'a00'),
        'deleted числом': mutate((j) => fieldsOf(j)['deleted'] = 1),
        'created_at отрицателен': mutate((j) => fieldsOf(j)['created_at'] = -1),
        'нет метки поля': mutate((j) => hlcOf(j).remove('title')),
        'битая метка': mutate((j) => hlcOf(j)['title'] = 'вчера'),
        'метка без поля': mutate((j) {
          fieldsOf(j).remove('title');
        }),
        'только created_at': mutate((j) {
          j['fields'] = {'created_at': 5};
          j['hlc'] = <String, Object?>{};
        }),
      };
      for (final MapEntry(key: name, value: json) in bad.entries) {
        expect(() => CardChange.fromJson(json), throwsProtocol, reason: name);
      }
    });

    test('граничные длины допустимы', () {
      final j = wire(validChangeJson()) as Map<String, Object?>;
      final fields = j['fields'] as Map<String, Object?>;
      fields['title'] = 'я' * 120;
      fields['description'] = 'x' * 2000;
      final c = CardChange.fromJson(j);
      expect(c.fields['title'], 'я' * 120);
    });
  });

  group('SyncRequest', () {
    test('roundtrip', () {
      const req = SyncRequest(
        cursor: 42,
        changes: [fullChange, partialChange],
        limit: 100,
      );
      final back = SyncRequest.fromJson(wire(req.toJson()));
      expect(back.cursor, 42);
      expect(back.limit, 100);
      expect(back.changes, [fullChange, partialChange]);
      expect(back.toJson(), req.toJson());
    });

    test('limit по умолчанию и пустые changes', () {
      final back =
          SyncRequest.fromJson(wire({'cursor': 0, 'changes': <Object?>[]}));
      expect(back.limit, maxSyncLimit);
      expect(back.changes, isEmpty);
      expect(const SyncRequest(cursor: 0).toJson(), {
        'cursor': 0,
        'changes': <Object?>[],
        'limit': 500,
      });
    });

    test('валидация', () {
      final ok = const SyncRequest(cursor: 1).toJson();
      expect(() => SyncRequest.fromJson({...ok, 'cursor': -1}), throwsProtocol);
      expect(
          () => SyncRequest.fromJson({...ok, 'cursor': '1'}), throwsProtocol);
      expect(() => SyncRequest.fromJson({...ok, 'limit': 0}), throwsProtocol);
      expect(() => SyncRequest.fromJson({...ok, 'limit': 501}), throwsProtocol);
      expect(() => SyncRequest.fromJson({...ok, 'changes': 'нет'}),
          throwsProtocol);
      expect(() => SyncRequest.fromJson({'cursor': 1}), throwsProtocol);
      expect(
        () => SyncRequest.fromJson({
          ...ok,
          'changes': List.filled(501, partialChange.toJson()),
        }),
        throwsProtocol,
      );
      expect(
        () => SyncRequest.fromJson({
          ...ok,
          'changes': [
            {'change_id': 'x'},
          ],
        }),
        throwsProtocol,
      );
    });
  });

  group('SyncResponse', () {
    test('roundtrip', () {
      const res = SyncResponse(
        applied: ['ch-1', 'ch-2'],
        changes: [partialChange],
        cursor: 77,
        hasMore: true,
      );
      final json = res.toJson();
      expect(
          json.keys, containsAll(['applied', 'changes', 'cursor', 'has_more']));
      final back = SyncResponse.fromJson(wire(json));
      expect(back.applied, ['ch-1', 'ch-2']);
      expect(back.changes, [partialChange]);
      expect(back.cursor, 77);
      expect(back.hasMore, isTrue);
      expect(back.toJson(), json);
    });

    test('валидация', () {
      final ok = const SyncResponse(cursor: 1).toJson();
      expect(SyncResponse.fromJson(wire(ok)).hasMore, isFalse);
      expect(
          () => SyncResponse.fromJson({
                ...ok,
                'applied': [1]
              }),
          throwsProtocol);
      expect(() => SyncResponse.fromJson({...ok, 'has_more': 'yes'}),
          throwsProtocol);
      expect(() => SyncResponse.fromJson({...ok}..remove('cursor')),
          throwsProtocol);
      expect(() => SyncResponse.fromJson(null), throwsProtocol);
    });
  });

  group('PairRequest / PairResponse', () {
    test('roundtrip', () {
      const req = PairRequest(
        code: 'ABC123',
        deviceId: 'dev-1',
        deviceName: 'Pixel 9 Игоря',
        platform: 'android',
      );
      final reqJson = req.toJson();
      expect(reqJson, {
        'code': 'ABC123',
        'device_id': 'dev-1',
        'device_name': 'Pixel 9 Игоря',
        'platform': 'android',
      });
      expect(PairRequest.fromJson(wire(reqJson)).toJson(), reqJson);

      const res = PairResponse(
        deviceToken: 'secret-token',
        serverId: 'srv-1',
        serverName: 'DESKTOP-01',
      );
      final resJson = res.toJson();
      expect(resJson, {
        'device_token': 'secret-token',
        'server_id': 'srv-1',
        'server_name': 'DESKTOP-01',
      });
      final back = PairResponse.fromJson(wire(resJson));
      expect(back.deviceToken, 'secret-token');
      expect(back.toJson(), resJson);
    });

    test('валидация', () {
      expect(() => PairRequest.fromJson({'code': 'A'}), throwsProtocol);
      expect(
        () => PairRequest.fromJson({
          'code': '',
          'device_id': 'd',
          'device_name': 'n',
          'platform': 'android',
        }),
        throwsProtocol,
      );
      expect(
        () => PairResponse.fromJson(
            {'device_token': 5, 'server_id': 's', 'server_name': 'n'}),
        throwsProtocol,
      );
    });
  });

  group('HelloResponse', () {
    test('roundtrip', () {
      const hello = HelloResponse(
        serverId: 'srv-1',
        serverName: 'DESKTOP-01',
        time: 1700000000000,
      );
      final json = hello.toJson();
      expect(json, {
        'server_id': 'srv-1',
        'server_name': 'DESKTOP-01',
        'proto': 1,
        'time': 1700000000000,
      });
      final back = HelloResponse.fromJson(wire(json));
      expect(back.toJson(), json);
      expect(back.isCompatible, isTrue);
    });

    test('чужая версия протокола разбирается, но несовместима', () {
      final back = HelloResponse.fromJson({
        'server_id': 's',
        'server_name': 'n',
        'proto': 2,
        'time': 1,
      });
      expect(back.proto, 2);
      expect(back.isCompatible, isFalse);
    });

    test('валидация', () {
      expect(
        () => HelloResponse.fromJson(
            {'server_id': 's', 'server_name': 'n', 'proto': '1', 'time': 1}),
        throwsProtocol,
      );
      expect(
        () => HelloResponse.fromJson(
            {'server_id': 's', 'server_name': 'n', 'proto': 1}),
        throwsProtocol,
      );
    });
  });
}

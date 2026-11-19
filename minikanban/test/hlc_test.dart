import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:minikanban/core/hlc.dart';

void main() {
  group('Hlc: строковое представление', () {
    test('toString имеет фиксированную ширину', () {
      expect(
        const Hlc(1700000000000, 1, 'node').toString(),
        '001700000000000:0001:node',
      );
      expect(
        const Hlc(5, 0xABCD, 'x').toString(),
        '000000000000005:abcd:x',
      );
      expect(Hlc.zero.toString(), '000000000000000:0000:');
    });

    test('parse обратен toString', () {
      const samples = [
        Hlc(1700000000000, 0, 'pc'),
        Hlc(1, 0xFFFF, 'a:b:c'), // двоеточия в nodeId допустимы
        Hlc(Hlc.maxMillis, 42, '3f2c-uuid'),
        Hlc.zero,
      ];
      for (final h in samples) {
        expect(Hlc.parse(h.toString()), h);
      }
    });

    test('parse отвергает мусор', () {
      for (final bad in [
        '',
        'abc',
        '1700000000000:0001:node', // millis не 15 цифр
        '001700000000000:1:node', // счётчик не 4 символа
        '001700000000000:ABCD:node', // верхний регистр hex
        '001700000000000-0001-node',
        '00170000000000x:0001:node',
      ]) {
        expect(() => Hlc.parse(bad), throwsFormatException, reason: bad);
        expect(Hlc.tryParse(bad), isNull, reason: bad);
      }
    });

    test('лексикографический порядок строк совпадает с compareTo', () {
      final rnd = Random(7);
      const nodes = ['a', 'b', 'pc', 'phone-1'];
      final list = List.generate(
        300,
        (_) => Hlc(
          1700000000000 + rnd.nextInt(5),
          rnd.nextInt(4) * 0x1111,
          nodes[rnd.nextInt(nodes.length)],
        ),
      );
      final byCompare = [...list]..sort();
      final byString = list.map((h) => h.toString()).toList()..sort();
      expect(byCompare.map((h) => h.toString()).toList(), byString);
    });
  });

  group('Hlc: сравнение', () {
    test('порядок: время, затем счётчик, затем nodeId', () {
      expect(const Hlc(1, 9, 'z') < const Hlc(2, 0, 'a'), isTrue);
      expect(const Hlc(2, 1, 'z') < const Hlc(2, 2, 'a'), isTrue);
      expect(const Hlc(2, 2, 'a') < const Hlc(2, 2, 'b'), isTrue);
      expect(const Hlc(2, 2, 'a').compareTo(const Hlc(2, 2, 'a')), 0);
      expect(const Hlc(2, 2, 'a') == const Hlc(2, 2, 'a'), isTrue);
      expect(const Hlc(2, 2, 'a') >= Hlc.zero, isTrue);
    });
  });

  group('Hlc.send', () {
    test('часы идут вперёд — берётся физическое время, счётчик 0', () {
      expect(const Hlc(100, 7, 'a').send(200), const Hlc(200, 0, 'a'));
    });

    test('часы стоят или идут назад — растёт счётчик', () {
      expect(const Hlc(100, 7, 'a').send(100), const Hlc(100, 8, 'a'));
      expect(const Hlc(100, 7, 'a').send(50), const Hlc(100, 8, 'a'));
    });

    test('переполнение счётчика переводит на следующую миллисекунду', () {
      const h = Hlc(100, Hlc.maxCounter, 'a');
      final next = h.send(100);
      expect(next, const Hlc(101, 0, 'a'));
      expect(next > h, isTrue);
    });

    test('метки строго монотонны', () {
      var h = const Hlc(0, 0, 'a');
      final rnd = Random(1);
      var now = 1000;
      for (var i = 0; i < 2000; i++) {
        now += rnd.nextInt(3) - 1; // часы могут шагнуть назад
        final next = h.send(now);
        expect(next > h, isTrue);
        h = next;
      }
    });
  });

  group('Hlc.receive', () {
    const local = Hlc(100, 2, 'a');

    test('равное время — max счётчиков + 1', () {
      expect(
        local.receive(const Hlc(100, 5, 'b'), 50),
        const Hlc(100, 6, 'a'),
      );
    });

    test('удалённая метка новее', () {
      expect(
        local.receive(const Hlc(200, 3, 'b'), 150),
        const Hlc(200, 4, 'a'),
      );
    });

    test('локальная метка новее', () {
      expect(
        const Hlc(300, 2, 'a').receive(const Hlc(200, 3, 'b'), 150),
        const Hlc(300, 3, 'a'),
      );
    });

    test('физическое время новее обеих', () {
      expect(
        local.receive(const Hlc(200, 3, 'b'), 500),
        const Hlc(500, 0, 'a'),
      );
    });

    test('результат больше обеих меток и сохраняет локальный nodeId', () {
      const remote = Hlc(100, Hlc.maxCounter, 'b');
      final r = local.receive(remote, 100);
      expect(r > local, isTrue);
      expect(r > remote, isTrue);
      expect(r.nodeId, 'a');
    });

    test('дрейф больше maxDrift — исключение', () {
      const now = 1000000;
      const limit = 60000;
      expect(
        local.receive(const Hlc(now + limit, 0, 'b'), now),
        const Hlc(now + limit, 1, 'a'),
      );
      expect(
        () => local.receive(const Hlc(now + limit + 1, 0, 'b'), now),
        throwsA(
          isA<HlcDriftException>()
              .having((e) => e.drift.inMilliseconds, 'drift', limit + 1),
        ),
      );
      // Свой допуск.
      expect(
        () => local.receive(
          const Hlc(now + 11, 0, 'b'),
          now,
          maxDrift: const Duration(milliseconds: 10),
        ),
        throwsA(isA<HlcDriftException>()),
      );
    });
  });

  group('HlcClock', () {
    test('send монотонен и использует nodeId часов', () {
      var now = 1000;
      final clock = HlcClock(nodeId: 'pc', now: () => now);
      final a = clock.send();
      final b = clock.send();
      now = 900; // часы перевели назад
      final c = clock.send();
      expect(a, const Hlc(1000, 0, 'pc'));
      expect(b, const Hlc(1000, 1, 'pc'));
      expect(c, const Hlc(1000, 2, 'pc'));
      expect(clock.last, c);
    });

    test('восстанавливается из сохранённой метки', () {
      final clock = HlcClock(
        nodeId: 'pc',
        last: const Hlc(5000, 3, 'old'),
        now: () => 1000,
      );
      expect(clock.send(), const Hlc(5000, 4, 'pc'));
    });

    test('receive с дрейфом не меняет состояние', () {
      final clock = HlcClock(nodeId: 'pc', now: () => 1000);
      final before = clock.send();
      expect(
        () => clock.receive(const Hlc(1000 + 60001, 0, 'ph')),
        throwsA(isA<HlcDriftException>()),
      );
      expect(clock.last, before);
      final after = clock.receive(const Hlc(2000, 0, 'ph'));
      expect(after, const Hlc(2000, 1, 'pc'));
    });

    test('пустой nodeId запрещён', () {
      expect(() => HlcClock(nodeId: ''), throwsArgumentError);
    });
  });
}

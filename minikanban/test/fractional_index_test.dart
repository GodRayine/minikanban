import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:minikanban/core/fractional_index.dart';

void expectStrictlyAscending(List<String> keys) {
  for (var i = 1; i < keys.length; i++) {
    expect(
      keys[i - 1].compareTo(keys[i]) < 0,
      isTrue,
      reason: 'позиция $i: "${keys[i - 1]}" должно быть < "${keys[i]}"',
    );
  }
}

void expectBetween(String? a, String key, String? b) {
  expect(isValidKey(key), isTrue, reason: 'некорректный ключ "$key"');
  if (a != null) {
    expect(a.compareTo(key) < 0, isTrue, reason: '"$a" < "$key"');
  }
  if (b != null) {
    expect(key.compareTo(b) < 0, isTrue, reason: '"$key" < "$b"');
  }
}

void main() {
  group('keyBetween: края', () {
    test('первый ключ', () {
      expect(keyBetween(null, null), 'a0');
      expect(firstKey, 'a0');
    });

    test('в конец', () {
      expect(keyBetween('a0', null), 'a1');
      expect(keyBetween('az', null), 'b00');
      expect(keyBetween('a0V', null), 'a1');
    });

    test('в начало', () {
      expect(keyBetween(null, 'a0'), 'Zz');
      expect(keyBetween(null, 'a1'), 'a0');
      expect(keyBetween(null, 'Z0'), 'Yzz');
      expect(keyBetween(null, 'a0V'), 'a0');
    });
  });

  group('keyBetween: между соседями', () {
    test('соседние целые', () {
      expect(keyBetween('a0', 'a1'), 'a0V');
      expectBetween('Zz', keyBetween('Zz', 'a0'), 'a0');
      expectBetween('az', keyBetween('az', 'b00'), 'b00');
    });

    test('соседние дробные', () {
      expect(keyBetween('a0', 'a0V'), 'a0G');
      for (final (a, b) in [
        ('a0V', 'a1'),
        ('a0G', 'a0V'),
        ('a0', 'a01'),
        ('a001', 'a002'),
        ('a0z', 'a1'),
        ('a0zz', 'a1'),
        ('a0y', 'a0z'),
      ]) {
        expectBetween(a, keyBetween(a, b), b);
      }
    });

    test('многократная вставка в одну и ту же щель', () {
      const lo = 'a0';
      var hi = 'a1';
      for (var i = 0; i < 300; i++) {
        final k = keyBetween(lo, hi);
        expectBetween(lo, k, hi);
        hi = k;
      }
      var low = 'a0';
      const high = 'a1';
      for (var i = 0; i < 300; i++) {
        final k = keyBetween(low, high);
        expectBetween(low, k, high);
        low = k;
      }
    });
  });

  group('keyBetween: ошибки', () {
    test('a >= b', () {
      expect(() => keyBetween('a1', 'a0'), throwsArgumentError);
      expect(() => keyBetween('a0', 'a0'), throwsArgumentError);
    });

    test('некорректные ключи', () {
      for (final bad in ['', '0', 'a', 'a00', 'a0-', 'b0', 'a0V0']) {
        expect(isValidKey(bad), isFalse, reason: bad);
        expect(() => keyBetween(bad, null), throwsArgumentError, reason: bad);
      }
      expect(isValidKey('a0'), isTrue);
      expect(isValidKey('b00'), isTrue);
      expect(isValidKey('Zz'), isTrue);
      expect(isValidKey('a0V'), isTrue);
    });
  });

  group('порядок при массовых вставках', () {
    test('1000 добавлений в конец — ключи короткие и упорядочены', () {
      final keys = <String>[];
      String? last;
      for (var i = 0; i < 1000; i++) {
        last = keyBetween(last, null);
        keys.add(last);
      }
      expectStrictlyAscending(keys);
      expect(keys.every((k) => k.length <= 3), isTrue);
    });

    test('1000 добавлений в начало — ключи короткие и упорядочены', () {
      final keys = <String>[];
      String? first;
      for (var i = 0; i < 1000; i++) {
        first = keyBetween(null, first);
        keys.insert(0, first);
      }
      expectStrictlyAscending(keys);
      expect(keys.every((k) => k.length <= 3), isTrue);
    });

    test('1000 случайных вставок сохраняют порядок', () {
      final rnd = Random(20261119);
      final keys = <String>[];
      for (var i = 0; i < 1000; i++) {
        final index = rnd.nextInt(keys.length + 1);
        final a = index == 0 ? null : keys[index - 1];
        final b = index == keys.length ? null : keys[index];
        final key = keyBetween(a, b);
        expectBetween(a, key, b);
        keys.insert(index, key);
      }
      expect(keys.length, 1000);
      expect(keys.toSet().length, 1000, reason: 'ключи уникальны');
      expectStrictlyAscending(keys);
      expect([...keys]..sort(), keys);
    });
  });

  group('nKeysBetween', () {
    test('n = 0 и n = 1', () {
      expect(nKeysBetween(null, null, 0), isEmpty);
      expect(nKeysBetween(null, null, 1), ['a0']);
      expect(() => nKeysBetween(null, null, -1), throwsArgumentError);
    });

    test('ключи упорядочены и лежат в границах', () {
      for (final (a, b, n) in [
        (null, null, 5),
        ('a0', null, 5),
        (null, 'a0', 5),
        ('a0', 'a1', 10),
        ('a0', 'a0V', 7),
        ('Zz', 'b00', 100),
      ]) {
        final keys = nKeysBetween(a, b, n);
        expect(keys.length, n);
        expectStrictlyAscending(keys);
        expectBetween(a, keys.first, b);
        expectBetween(a, keys.last, b);
      }
    });

    test('в конец — последовательные целые', () {
      expect(nKeysBetween('a0', null, 3), ['a1', 'a2', 'a3']);
      expect(nKeysBetween(null, 'a0', 3), ['Zx', 'Zy', 'Zz']);
    });
  });
}

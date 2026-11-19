/// Дробный строковый индекс (base62) для порядка карточек в колонке.
///
/// Ключ = «целая часть» переменной длины + необязательная дробная часть.
/// Первый символ кодирует длину целой части (`a`..`z` — 2..27 символов,
/// `Z`..`A` — 2..27 символов для «отрицательных»), поэтому добавление
/// в конец/начало списка просто увеличивает/уменьшает целую часть и ключи
/// не растут в длину; вставка между соседями берёт середину дробных частей.
///
/// Ключи сравниваются как обычные ASCII-строки (в SQLite — collation BINARY,
/// он же по умолчанию). Алфавит: `0-9A-Za-z` в порядке ASCII.
library;

const String _digits =
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
const int _base = 62;

/// Ключ первой карточки в пустом списке.
const String firstKey = 'a0';

final String _smallestInteger = 'A${'0' * 26}';
final RegExp _alphabet = RegExp(r'^[0-9A-Za-z]+$');

int _code(String ch) => ch.codeUnitAt(0);

bool _less(String a, String b) => a.compareTo(b) < 0;

/// Длина целой части по её первому символу.
int _integerLength(String head) {
  final c = _code(head);
  if (c >= 0x61 && c <= 0x7A) return c - 0x61 + 2; // a..z
  if (c >= 0x41 && c <= 0x5A) return 0x5A - c + 2; // A..Z
  throw ArgumentError.value(head, 'key', 'некорректный первый символ ключа');
}

String _integerPart(String key) {
  final len = _integerLength(key[0]);
  if (len > key.length) {
    throw ArgumentError.value(key, 'key', 'ключ короче своей целой части');
  }
  return key.substring(0, len);
}

/// Проверяет, что [key] — корректный ключ порядка.
bool isValidKey(String key) {
  try {
    _validate(key);
    return true;
  } on ArgumentError {
    return false;
  }
}

void _validate(String key) {
  if (key.isEmpty || !_alphabet.hasMatch(key)) {
    throw ArgumentError.value(key, 'key', 'ключ пуст или содержит не base62');
  }
  if (key == _smallestInteger) {
    throw ArgumentError.value(key, 'key', 'наименьший ключ недопустим');
  }
  final integer = _integerPart(key);
  final fraction = key.substring(integer.length);
  if (fraction.endsWith('0')) {
    throw ArgumentError.value(key, 'key', 'дробная часть оканчивается на 0');
  }
}

/// Середина между дробными частями [a] и [b] (`null` — «единица»).
/// Требуется `a < b`; обе без хвостовых нулей. Результат тоже без них.
String _midpoint(String a, String? b) {
  if (b != null) {
    // Общий префикс (a мысленно дополняется нулями).
    var n = 0;
    while (n < b.length && (n < a.length ? a[n] : '0') == b[n]) {
      n++;
    }
    if (n > 0) {
      return b.substring(0, n) +
          _midpoint(n < a.length ? a.substring(n) : '', b.substring(n));
    }
  }
  final digitA = a.isEmpty ? 0 : _digits.indexOf(a[0]);
  final digitB = b == null ? _base : _digits.indexOf(b[0]);
  if (digitB - digitA > 1) {
    return _digits[(digitA + digitB + 1) ~/ 2];
  }
  // Первые цифры соседние.
  if (b != null && b.length > 1) return b.substring(0, 1);
  return _digits[digitA] + _midpoint(a.isEmpty ? '' : a.substring(1), null);
}

/// Целая часть + 1; `null`, если больше некуда.
String? _incrementInteger(String x) {
  final head = x[0];
  final digs = x.substring(1).split('');
  var carry = true;
  for (var i = digs.length - 1; carry && i >= 0; i--) {
    final d = _digits.indexOf(digs[i]) + 1;
    if (d == _base) {
      digs[i] = '0';
    } else {
      digs[i] = _digits[d];
      carry = false;
    }
  }
  if (!carry) return head + digs.join();
  if (head == 'Z') return 'a0';
  if (head == 'z') return null;
  final next = String.fromCharCode(_code(head) + 1);
  if (_code(next) > 0x61) {
    digs.add('0'); // положительные: длина растёт
  } else {
    digs.removeLast(); // отрицательные: длина убывает
  }
  return next + digs.join();
}

/// Целая часть − 1; `null`, если меньше некуда.
String? _decrementInteger(String x) {
  final head = x[0];
  final digs = x.substring(1).split('');
  var borrow = true;
  for (var i = digs.length - 1; borrow && i >= 0; i--) {
    final d = _digits.indexOf(digs[i]) - 1;
    if (d == -1) {
      digs[i] = 'z';
    } else {
      digs[i] = _digits[d];
      borrow = false;
    }
  }
  if (!borrow) return head + digs.join();
  if (head == 'a') return 'Zz';
  if (head == 'A') return null;
  final prev = String.fromCharCode(_code(head) - 1);
  if (_code(prev) < 0x5A) {
    digs.add('z'); // отрицательные: длина растёт
  } else {
    digs.removeLast(); // положительные: длина убывает
  }
  return prev + digs.join();
}

/// Возвращает ключ строго между [a] и [b].
///
/// `a == null` — вставка в начало, `b == null` — в конец, оба `null` —
/// первый ключ ([firstKey]). Бросает [ArgumentError], если ключи некорректны
/// или `a >= b`, и [StateError], если пространство ключей исчерпано
/// (практически недостижимо).
String keyBetween(String? a, String? b) {
  if (a != null) _validate(a);
  if (b != null) _validate(b);
  if (a != null && b != null && !_less(a, b)) {
    throw ArgumentError('keyBetween: требуется a < b, получено "$a" >= "$b"');
  }

  if (a == null) {
    if (b == null) return firstKey;
    final ib = _integerPart(b);
    final fb = b.substring(ib.length);
    if (ib == _smallestInteger) return ib + _midpoint('', fb);
    if (_less(ib, b)) return ib;
    final res = _decrementInteger(ib);
    if (res == null) throw StateError('Пространство ключей исчерпано снизу');
    return res;
  }

  final ia = _integerPart(a);
  final fa = a.substring(ia.length);

  if (b == null) {
    final next = _incrementInteger(ia);
    return next ?? ia + _midpoint(fa, null);
  }

  final ib = _integerPart(b);
  final fb = b.substring(ib.length);
  if (ia == ib) return ia + _midpoint(fa, fb);

  final next = _incrementInteger(ia);
  if (next == null) throw StateError('Пространство ключей исчерпано сверху');
  if (_less(next, b)) return next;
  return ia + _midpoint(fa, null);
}

/// Возвращает [n] возрастающих ключей строго между [a] и [b].
List<String> nKeysBetween(String? a, String? b, int n) {
  if (n < 0) throw ArgumentError.value(n, 'n', 'не может быть отрицательным');
  if (n == 0) return const [];
  if (n == 1) return [keyBetween(a, b)];

  if (b == null) {
    var c = keyBetween(a, null);
    final result = [c];
    for (var i = 1; i < n; i++) {
      c = keyBetween(c, null);
      result.add(c);
    }
    return result;
  }
  if (a == null) {
    var c = keyBetween(null, b);
    final result = [c];
    for (var i = 1; i < n; i++) {
      c = keyBetween(null, c);
      result.add(c);
    }
    return result.reversed.toList();
  }
  final mid = n ~/ 2;
  final c = keyBetween(a, b);
  return [
    ...nKeysBetween(a, c, mid),
    c,
    ...nKeysBetween(c, b, n - mid - 1),
  ];
}

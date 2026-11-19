/// Hybrid Logical Clock (HLC) — метка времени для LWW-слияния по полям.
library;

/// Удалённая метка слишком далеко в будущем относительно локальных часов.
class HlcDriftException implements Exception {
  const HlcDriftException({
    required this.remoteMillis,
    required this.nowMillis,
    required this.maxDrift,
  });

  final int remoteMillis;
  final int nowMillis;
  final Duration maxDrift;

  /// На сколько удалённая метка опережает локальные часы.
  Duration get drift => Duration(milliseconds: remoteMillis - nowMillis);

  @override
  String toString() =>
      'HlcDriftException: удалённые часы опережают локальные на '
      '${drift.inMilliseconds} мс (допустимо ${maxDrift.inMilliseconds} мс)';
}

/// Неизменяемая HLC-метка: физическое время (мс), счётчик и id узла.
///
/// Строковый вид `<millis, 15 цифр>:<counter, 4 hex в нижнем регистре>:<nodeId>`
/// имеет фиксированную ширину первых двух частей, поэтому лексикографическое
/// сравнение строк совпадает с [compareTo] — метки можно сравнивать прямо
/// в SQL (`hlc_title < ?`).
///
/// Сравнение полное: при равных времени и счётчике порядок задаёт [nodeId],
/// что даёт детерминированный tie-break между устройствами.
final class Hlc implements Comparable<Hlc> {
  const Hlc(this.millis, this.counter, this.nodeId)
      : assert(millis >= 0 && millis <= maxMillis, 'millis вне диапазона'),
        assert(counter >= 0 && counter <= maxCounter, 'counter вне диапазона');

  /// Разбирает строку формата [toString]. Бросает [FormatException].
  factory Hlc.parse(String source) {
    final m = _pattern.firstMatch(source);
    if (m == null) {
      throw FormatException('Некорректная HLC-метка', source);
    }
    return Hlc(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!, radix: 16),
      m.group(3)!,
    );
  }

  /// Как [Hlc.parse], но возвращает `null` вместо исключения.
  static Hlc? tryParse(String source) {
    try {
      return Hlc.parse(source);
    } on FormatException {
      return null;
    }
  }

  /// Минимально возможная метка: меньше либо равна любой другой.
  static const Hlc zero = Hlc(0, 0, '');

  static const int maxMillis = 999999999999999; // 15 цифр
  static const int maxCounter = 0xFFFF; // 4 hex-цифры
  static const Duration defaultMaxDrift = Duration(minutes: 1);

  static final RegExp _pattern =
      RegExp(r'^(\d{15}):([0-9a-f]{4}):(.*)$', dotAll: true);

  /// Физическая часть — мс с начала эпохи Unix (UTC).
  final int millis;

  /// Логический счётчик внутри одной миллисекунды.
  final int counter;

  /// Идентификатор узла (устройства), выпустившего метку.
  final String nodeId;

  /// Новая метка для локального события (правка/отправка).
  ///
  /// Результат строго больше `this`. Дрейф здесь намеренно НЕ проверяется:
  /// если системные часы перевели назад, метка продолжает расти от
  /// уже достигнутого логического времени (растёт счётчик) — блокировать
  /// локальные правки пользователя из-за часов хуже, чем временно
  /// «опережать» физическое время.
  Hlc send(int nowMillis) => nowMillis > millis
      ? Hlc(nowMillis, 0, nodeId)
      : _next(millis, counter, nodeId);

  /// Новая локальная метка после получения удалённой метки [remote].
  ///
  /// Результат строго больше и `this`, и [remote]; [nodeId] остаётся
  /// локальным.
  ///
  /// Защита от дрейфа: если [remote] опережает локальные физические часы
  /// больше чем на [maxDrift], бросается [HlcDriftException] и локальные
  /// часы НЕ сдвигаются. Выбрано исключение, а не clamp: clamp молча исказил
  /// бы причинность, а исключение позволяет вызывающему коду решить, что
  /// делать (показать «проверьте время на устройстве», записать в лог).
  /// Само слияние данных (`mergeCard`) от этих часов не зависит и остаётся
  /// детерминированным — исключение лишь не даёт «отравить» локальные часы
  /// меткой из далёкого будущего.
  Hlc receive(
    Hlc remote,
    int nowMillis, {
    Duration maxDrift = defaultMaxDrift,
  }) {
    if (remote.millis - nowMillis > maxDrift.inMilliseconds) {
      throw HlcDriftException(
        remoteMillis: remote.millis,
        nowMillis: nowMillis,
        maxDrift: maxDrift,
      );
    }
    var top = millis;
    if (remote.millis > top) top = remote.millis;
    if (nowMillis > top) top = nowMillis;

    final localIsTop = top == millis;
    final remoteIsTop = top == remote.millis;
    if (localIsTop && remoteIsTop) {
      final c = counter > remote.counter ? counter : remote.counter;
      return _next(top, c, nodeId);
    }
    if (localIsTop) return _next(top, counter, nodeId);
    if (remoteIsTop) return _next(top, remote.counter, nodeId);
    return Hlc(top, 0, nodeId);
  }

  /// Следующая метка после `(millis, counter)`; при переполнении счётчика
  /// переходит на следующую миллисекунду, сохраняя монотонность.
  static Hlc _next(int millis, int counter, String nodeId) =>
      counter >= maxCounter
          ? Hlc(millis + 1, 0, nodeId)
          : Hlc(millis, counter + 1, nodeId);

  @override
  int compareTo(Hlc other) {
    if (millis != other.millis) return millis < other.millis ? -1 : 1;
    if (counter != other.counter) return counter < other.counter ? -1 : 1;
    return nodeId.compareTo(other.nodeId);
  }

  bool operator <(Hlc other) => compareTo(other) < 0;
  bool operator <=(Hlc other) => compareTo(other) <= 0;
  bool operator >(Hlc other) => compareTo(other) > 0;
  bool operator >=(Hlc other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is Hlc &&
      other.millis == millis &&
      other.counter == counter &&
      other.nodeId == nodeId;

  @override
  int get hashCode => Object.hash(millis, counter, nodeId);

  @override
  String toString() => '${millis.toString().padLeft(15, '0')}:'
      '${counter.toRadixString(16).padLeft(4, '0')}:'
      '$nodeId';
}

/// Изменяемые часы узла: хранят последнюю выданную метку.
///
/// Последнюю метку ([last]) нужно сохранять (meta `hlc_last`) и
/// восстанавливать при старте, иначе после перевода часов назад новые
/// правки могут проиграть собственным старым.
class HlcClock {
  HlcClock({
    required String nodeId,
    Hlc? last,
    int Function()? now,
    this.maxDrift = Hlc.defaultMaxDrift,
  })  : _now = now ?? _systemNow,
        _last = Hlc(last?.millis ?? 0, last?.counter ?? 0, nodeId) {
    if (nodeId.isEmpty) {
      throw ArgumentError.value(nodeId, 'nodeId', 'не должен быть пустым');
    }
  }

  final int Function() _now;
  final Duration maxDrift;
  Hlc _last;

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  String get nodeId => _last.nodeId;

  /// Последняя выданная (или восстановленная) метка.
  Hlc get last => _last;

  /// Выдаёт метку для локальной правки.
  Hlc send() => _last = _last.send(_now());

  /// Учитывает удалённую метку. Может бросить [HlcDriftException]
  /// (см. [Hlc.receive]) — состояние часов при этом не меняется.
  Hlc receive(Hlc remote) =>
      _last = _last.receive(remote, _now(), maxDrift: maxDrift);
}

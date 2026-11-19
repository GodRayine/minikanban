/// Доменная модель: колонки доски и карточка.
library;

import '../core/hlc.dart';

/// Колонка доски. Набор фиксирован, [code] хранится в БД и передаётся в sync.
enum BoardColumn {
  todo(0, 'Не начато'),
  doing(1, 'В процессе'),
  done(2, 'Готово');

  const BoardColumn(this.code, this.label);

  /// Целочисленный код (0..2) для БД и протокола.
  final int code;

  /// Подпись для интерфейса.
  final String label;

  /// Колонка по коду или `null`, если код неизвестен.
  static BoardColumn? tryFromCode(int code) => switch (code) {
        0 => todo,
        1 => doing,
        2 => done,
        _ => null,
      };

  /// Колонка по коду; бросает [ArgumentError] для неизвестного кода.
  static BoardColumn fromCode(int code) =>
      tryFromCode(code) ??
      (throw ArgumentError.value(code, 'code', 'неизвестная колонка'));
}

/// Изменяемые поля карточки, у каждого своя HLC-метка (LWW по полям).
enum CardField {
  title('title'),
  description('description'),
  column('column'),
  pos('pos'),
  deleted('deleted');

  const CardField(this.wire);

  /// Имя поля в протоколе и суффикс столбца `hlc_<wire>` в БД.
  final String wire;

  static CardField? tryParse(String wire) {
    for (final f in values) {
      if (f.wire == wire) return f;
    }
    return null;
  }
}

/// Нарушение ограничений карточки (длина заголовка/описания).
class CardValidationException implements Exception {
  const CardValidationException(this.message);

  /// Сообщение для пользователя.
  final String message;

  @override
  String toString() => 'CardValidationException: $message';
}

/// Неизменяемая карточка канбана.
///
/// Для каждого изменяемого поля хранится HLC последней записи — по ним
/// выполняется слияние. [serverSeq] назначает только ПК-хаб (0 — ещё
/// не назначен). [createdAt] — мс эпохи Unix, 0 — «неизвестно».
final class KanbanCard {
  const KanbanCard({
    required this.id,
    required this.title,
    required this.pos,
    required this.createdAt,
    this.description = '',
    this.column = BoardColumn.todo,
    this.deleted = false,
    this.hlcTitle = Hlc.zero,
    this.hlcDescription = Hlc.zero,
    this.hlcColumn = Hlc.zero,
    this.hlcPos = Hlc.zero,
    this.hlcDeleted = Hlc.zero,
    this.serverSeq = 0,
  });

  /// Новая локальная карточка: проверяет поля, обрезает пробелы заголовка
  /// и ставит одну метку [hlc] на все поля.
  factory KanbanCard.create({
    required String id,
    required String title,
    required String pos,
    required int createdAt,
    required Hlc hlc,
    String description = '',
    BoardColumn column = BoardColumn.todo,
  }) =>
      KanbanCard(
        id: id,
        title: normalizeTitle(title),
        description: checkDescription(description),
        column: column,
        pos: pos,
        createdAt: createdAt,
        hlcTitle: hlc,
        hlcDescription: hlc,
        hlcColumn: hlc,
        hlcPos: hlc,
        hlcDeleted: hlc,
      );

  static const int maxTitleLength = 120;
  static const int maxDescriptionLength = 2000;

  final String id;
  final String title;
  final String description;
  final BoardColumn column;

  /// Дробный строковый индекс; порядок в колонке — `(pos, id)`.
  final String pos;

  /// Tombstone: удалённая карточка остаётся в БД ради синхронизации.
  final bool deleted;

  final int createdAt;

  final Hlc hlcTitle;
  final Hlc hlcDescription;
  final Hlc hlcColumn;
  final Hlc hlcPos;
  final Hlc hlcDeleted;

  final int serverSeq;

  // --- Валидация -----------------------------------------------------------

  /// Текст ошибки заголовка или `null`, если он допустим.
  /// Длина считается после `trim`, в символах Unicode (code points).
  static String? titleError(String raw) {
    final length = raw.trim().runes.length;
    if (length == 0) return 'Введите заголовок';
    if (length > maxTitleLength) {
      return 'Заголовок не длиннее $maxTitleLength символов';
    }
    return null;
  }

  /// Текст ошибки описания или `null`, если оно допустимо.
  static String? descriptionError(String raw) =>
      raw.runes.length > maxDescriptionLength
          ? 'Описание не длиннее $maxDescriptionLength символов'
          : null;

  /// Обрезает пробелы и проверяет заголовок.
  static String normalizeTitle(String raw) {
    final error = titleError(raw);
    if (error != null) throw CardValidationException(error);
    return raw.trim();
  }

  /// Проверяет описание и возвращает его без изменений.
  static String checkDescription(String raw) {
    final error = descriptionError(raw);
    if (error != null) throw CardValidationException(error);
    return raw;
  }

  // --- Доступ по полю ------------------------------------------------------

  /// HLC-метка поля [field].
  Hlc hlcOf(CardField field) => switch (field) {
        CardField.title => hlcTitle,
        CardField.description => hlcDescription,
        CardField.column => hlcColumn,
        CardField.pos => hlcPos,
        CardField.deleted => hlcDeleted,
      };

  /// Наибольшая из меток полей.
  Hlc get maxHlc {
    var top = hlcTitle;
    for (final f in CardField.values) {
      final h = hlcOf(f);
      if (h > top) top = h;
    }
    return top;
  }

  // --- Изменение -----------------------------------------------------------

  KanbanCard copyWith({
    String? id,
    String? title,
    String? description,
    BoardColumn? column,
    String? pos,
    bool? deleted,
    int? createdAt,
    Hlc? hlcTitle,
    Hlc? hlcDescription,
    Hlc? hlcColumn,
    Hlc? hlcPos,
    Hlc? hlcDeleted,
    int? serverSeq,
  }) =>
      KanbanCard(
        id: id ?? this.id,
        title: title ?? this.title,
        description: description ?? this.description,
        column: column ?? this.column,
        pos: pos ?? this.pos,
        deleted: deleted ?? this.deleted,
        createdAt: createdAt ?? this.createdAt,
        hlcTitle: hlcTitle ?? this.hlcTitle,
        hlcDescription: hlcDescription ?? this.hlcDescription,
        hlcColumn: hlcColumn ?? this.hlcColumn,
        hlcPos: hlcPos ?? this.hlcPos,
        hlcDeleted: hlcDeleted ?? this.hlcDeleted,
        serverSeq: serverSeq ?? this.serverSeq,
      );

  /// Локальная правка: меняет переданные поля и ставит им метку [hlc].
  ///
  /// Поля, значение которых не изменилось, не трогаются (их метка остаётся
  /// прежней), поэтому в исходящее изменение попадёт только реальная правка.
  /// Заголовок и описание проверяются ([CardValidationException]).
  KanbanCard edit({
    required Hlc hlc,
    String? title,
    String? description,
    BoardColumn? column,
    String? pos,
    bool? deleted,
  }) {
    var next = this;
    if (title != null) {
      final value = normalizeTitle(title);
      if (value != this.title) {
        next = next.copyWith(title: value, hlcTitle: hlc);
      }
    }
    if (description != null) {
      final value = checkDescription(description);
      if (value != this.description) {
        next = next.copyWith(description: value, hlcDescription: hlc);
      }
    }
    if (column != null && column != this.column) {
      next = next.copyWith(column: column, hlcColumn: hlc);
    }
    if (pos != null && pos != this.pos) {
      next = next.copyWith(pos: pos, hlcPos: hlc);
    }
    if (deleted != null && deleted != this.deleted) {
      next = next.copyWith(deleted: deleted, hlcDeleted: hlc);
    }
    return next;
  }

  /// Сравнение для сортировки внутри колонки: `(pos, id)`.
  static int compareByPosition(KanbanCard a, KanbanCard b) {
    final byPos = a.pos.compareTo(b.pos);
    return byPos != 0 ? byPos : a.id.compareTo(b.id);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is KanbanCard &&
          other.id == id &&
          other.title == title &&
          other.description == description &&
          other.column == column &&
          other.pos == pos &&
          other.deleted == deleted &&
          other.createdAt == createdAt &&
          other.hlcTitle == hlcTitle &&
          other.hlcDescription == hlcDescription &&
          other.hlcColumn == hlcColumn &&
          other.hlcPos == hlcPos &&
          other.hlcDeleted == hlcDeleted &&
          other.serverSeq == serverSeq;

  @override
  int get hashCode => Object.hash(
        id,
        title,
        description,
        column,
        pos,
        deleted,
        createdAt,
        hlcTitle,
        hlcDescription,
        hlcColumn,
        hlcPos,
        hlcDeleted,
        serverSeq,
      );

  @override
  String toString() => 'KanbanCard($id, "$title", ${column.name}, pos=$pos, '
      'deleted=$deleted, seq=$serverSeq)';
}

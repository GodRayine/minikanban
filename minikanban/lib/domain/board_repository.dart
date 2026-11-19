/// Интерфейс хранилища доски; реализация (SQLite) появится на этапе M2.
library;

import 'card.dart';

/// Снимок доски: неудалённые карточки по колонкам, уже отсортированные
/// по `(pos, id)`.
final class BoardSnapshot {
  const BoardSnapshot(this._columns);

  /// Собирает снимок из произвольного набора карточек: отбрасывает
  /// удалённые, раскладывает по колонкам и сортирует.
  factory BoardSnapshot.fromCards(Iterable<KanbanCard> cards) {
    final columns = {
      for (final c in BoardColumn.values) c: <KanbanCard>[],
    };
    for (final card in cards) {
      if (!card.deleted) columns[card.column]!.add(card);
    }
    for (final list in columns.values) {
      list.sort(KanbanCard.compareByPosition);
    }
    return BoardSnapshot({
      for (final e in columns.entries) e.key: List.unmodifiable(e.value),
    });
  }

  static const BoardSnapshot empty = BoardSnapshot({});

  final Map<BoardColumn, List<KanbanCard>> _columns;

  /// Карточки колонки [column] сверху вниз.
  List<KanbanCard> cards(BoardColumn column) => _columns[column] ?? const [];

  /// Всего карточек на доске.
  int get length =>
      BoardColumn.values.fold(0, (sum, c) => sum + cards(c).length);
}

/// Операции над доской. Все методы работают с локальной БД (офлайн);
/// реализация сама выдаёт HLC-метки и кладёт изменения в outbox.
///
/// Методы, получающие `id`, завершаются с [StateError], если карточки нет;
/// некорректные заголовок/описание — [CardValidationException].
abstract interface class BoardRepository {
  /// Поток снимков доски: текущее состояние сразу и затем после каждого
  /// изменения (локального или пришедшего при синхронизации).
  Stream<BoardSnapshot> watchBoard();

  /// Создаёт карточку в конце колонки [column].
  Future<KanbanCard> create({
    required String title,
    String description = '',
    BoardColumn column = BoardColumn.todo,
  });

  /// Меняет заголовок и/или описание (`null` — не менять).
  Future<KanbanCard> update(String id, {String? title, String? description});

  /// Переносит карточку в [column] и ставит её между соседями:
  /// [afterId] — карточка, которая окажется сразу НАД перемещаемой,
  /// [beforeId] — сразу ПОД ней. Только [beforeId] — вставка перед ней,
  /// только [afterId] — после неё, оба `null` — в конец колонки.
  Future<KanbanCard> move(
    String id, {
    required BoardColumn column,
    String? beforeId,
    String? afterId,
  });

  /// Помечает карточку удалённой (tombstone).
  Future<void> delete(String id);

  /// Отменяет удаление.
  Future<KanbanCard> restore(String id);
}

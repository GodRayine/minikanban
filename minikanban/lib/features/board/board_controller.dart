/// Действия пользователя над доской: создание, правка, перенос, удаление
/// с отменой. Виджеты вызывают контроллер и не обращаются к репозиторию
/// напрямую.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/providers.dart';
import '../../domain/board_repository.dart';
import '../../domain/card.dart';

/// Ключ корневого [ScaffoldMessenger]: SnackBar с «Отменить» должен жить
/// дольше экрана/диалога, из которого вызвано действие.
final scaffoldMessengerKeyProvider =
    Provider<GlobalKey<ScaffoldMessengerState>>(
  (ref) => GlobalKey<ScaffoldMessengerState>(),
);

final boardControllerProvider = Provider<BoardController>(BoardController.new);

class BoardController {
  BoardController(this._ref);

  final Ref _ref;

  /// Сколько виден SnackBar с отменой.
  static const Duration undoDuration = Duration(seconds: 6);

  BoardRepository get _repo => _ref.read(boardRepositoryProvider);

  BoardSnapshot get _board =>
      _ref.read(boardProvider).valueOrNull ?? BoardSnapshot.empty;

  // --- Создание и правка ----------------------------------------------------

  /// Создаёт карточку в конце [column]. `null`, если заголовок некорректен
  /// (сообщение показано пользователю).
  Future<KanbanCard?> create({
    required String title,
    String description = '',
    BoardColumn column = BoardColumn.todo,
  }) =>
      _guard(
        () => _repo.create(
          title: title,
          description: description,
          column: column,
        ),
      );

  /// Сохраняет результат редактора: текст и, если колонка изменилась,
  /// перенос в конец новой колонки.
  Future<void> saveEdits(
    KanbanCard card, {
    required String title,
    required String description,
    required BoardColumn column,
  }) =>
      _guard(() async {
        await _repo.update(card.id, title: title, description: description);
        if (column != card.column) {
          await _repo.move(card.id, column: column);
        }
      });

  // --- Удаление ---------------------------------------------------------------

  /// Удаляет карточку и показывает «Задача удалена · Отменить».
  Future<void> delete(KanbanCard card) async {
    final done = await _guard(() async {
      await _repo.delete(card.id);
      return true;
    });
    if (done ?? false) {
      _showUndo('Задача удалена', () => _repo.restore(card.id));
    }
  }

  // --- Перенос ----------------------------------------------------------------

  /// Переносит карточку в конец [column] (свайп, bottom sheet) и
  /// предлагает отмену — возврат на прежнее место.
  Future<void> moveToColumn(KanbanCard card, BoardColumn column) async {
    if (column == card.column) return;
    final source = _board.cards(card.column);
    final at = source.indexWhere((c) => c.id == card.id);
    final nextId = at >= 0 && at + 1 < source.length ? source[at + 1].id : null;

    final moved = await _guard(() => _repo.move(card.id, column: column));
    if (moved == null) return;
    _showUndo(
      'Задача перемещена в „${column.label}“',
      () => _repo.move(card.id, column: card.column, beforeId: nextId),
    );
  }

  /// Перетаскивание: ставит карточку в [column] на место [index] — номер
  /// промежутка между карточками колонки в её текущем виде (0 — перед
  /// первой, `length` — после последней).
  Future<void> dropAt(KanbanCard card, BoardColumn column, int index) {
    final others = <KanbanCard>[];
    var slot = 0;
    final cards = _board.cards(column);
    for (var i = 0; i < cards.length; i++) {
      if (cards[i].id == card.id) continue;
      if (i < index) slot++;
      others.add(cards[i]);
    }
    return _place(card.id, column, others, slot);
  }

  /// Перестановка внутри колонки: карточка с места [oldIndex] встаёт на
  /// место [newIndex] (индексы итогового списка).
  Future<void> reorder(BoardColumn column, int oldIndex, int newIndex) async {
    final cards = _board.cards(column);
    if (oldIndex < 0 || oldIndex >= cards.length || oldIndex == newIndex) {
      return;
    }
    final card = cards[oldIndex];
    final others = [...cards]..removeAt(oldIndex);
    await _place(card.id, column, others, newIndex.clamp(0, others.length));
  }

  /// Клавиатура: перенос в соседнюю колонку ([delta] = ±1), в её конец.
  Future<void> shiftColumn(KanbanCard card, int delta) async {
    final target = BoardColumn.tryFromCode(card.column.code + delta);
    if (target == null) return;
    await _guard(() => _repo.move(card.id, column: target));
  }

  /// Клавиатура: на одну позицию вверх/вниз ([delta] = ∓1) внутри колонки.
  Future<void> shiftOrder(KanbanCard card, int delta) async {
    final cards = _board.cards(card.column);
    final at = cards.indexWhere((c) => c.id == card.id);
    if (at < 0) return;
    await reorder(card.column, at, at + delta.sign);
  }

  Future<void> _place(
    String id,
    BoardColumn column,
    List<KanbanCard> others,
    int slot,
  ) =>
      _guard(
        () => _repo.move(
          id,
          column: column,
          afterId: slot > 0 ? others[slot - 1].id : null,
          beforeId: slot < others.length ? others[slot].id : null,
        ),
      );

  // --- Сообщения ------------------------------------------------------------

  /// Показывает короткое сообщение внизу экрана.
  void notify(String message) {
    final messenger = _ref.read(scaffoldMessengerKeyProvider).currentState;
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _showUndo(String message, Future<Object?> Function() undo) {
    final messenger = _ref.read(scaffoldMessengerKeyProvider).currentState;
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: undoDuration,
          persist: false,
          action: SnackBarAction(
            label: 'Отменить',
            onPressed: () => _guard(undo),
          ),
        ),
      );
  }

  /// Выполняет действие; ожидаемые ошибки превращает в сообщение.
  Future<T?> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on CardValidationException catch (e) {
      notify(e.message);
    } on StateError {
      notify('Задача не найдена — возможно, её уже удалили');
    }
    return null;
  }
}

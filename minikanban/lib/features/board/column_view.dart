/// Колонка доски в широком режиме: заголовок, карточки с drag&drop и
/// клавиатурой, поле «Добавить задачу».
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../domain/card.dart';
import 'board_controller.dart';
import 'board_text.dart';
import 'card_editor.dart';
import 'card_tile.dart';

/// Место вставки при перетаскивании: промежуток [index] в колонке
/// [column] (0 — перед первой карточкой).
typedef DropSlot = ({BoardColumn column, int index});

class ColumnView extends ConsumerStatefulWidget {
  const ColumnView({
    super.key,
    required this.column,
    required this.cards,
    required this.keyFor,
    required this.dropSlot,
    required this.addFocusNode,
  });

  final BoardColumn column;
  final List<KanbanCard> cards;

  /// Постоянный ключ карточки: при переносе между колонками плитка
  /// переезжает вместе с состоянием и не теряет фокус клавиатуры.
  final GlobalKey Function(String cardId) keyFor;

  /// Общее для всех колонок место вставки (линия 2px).
  final ValueNotifier<DropSlot?> dropSlot;

  /// Фокус поля «Добавить задачу» (клавиша N).
  final FocusNode addFocusNode;

  @override
  ConsumerState<ColumnView> createState() => _ColumnViewState();
}

class _ColumnViewState extends ConsumerState<ColumnView> {
  final TextEditingController _newTitle = TextEditingController();

  BoardController get _controller => ref.read(boardControllerProvider);

  /// Мышью карточку тянут сразу, пальцем — после долгого нажатия
  /// (иначе жест спорит с прокруткой колонки).
  static bool get _immediateDrag => switch (defaultTargetPlatform) {
        TargetPlatform.windows ||
        TargetPlatform.linux ||
        TargetPlatform.macOS =>
          true,
        _ => false,
      };

  @override
  void dispose() {
    _newTitle.dispose();
    super.dispose();
  }

  // --- Drag & drop ------------------------------------------------------------

  /// Номер промежутка под указателем: сколько карточек колонки лежит
  /// выше него (сравнение с серединой каждой карточки).
  int _slotAt(Offset global) {
    var index = 0;
    for (final card in widget.cards) {
      final box = widget.keyFor(card.id).currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      final middle = box.localToGlobal(Offset(0, box.size.height / 2)).dy;
      if (middle < global.dy) index++;
    }
    return index;
  }

  void _onDragMove(DragTargetDetails<KanbanCard> details) {
    widget.dropSlot.value =
        (column: widget.column, index: _slotAt(details.offset));
  }

  void _onDragLeave(KanbanCard? _) {
    if (widget.dropSlot.value?.column == widget.column) {
      widget.dropSlot.value = null;
    }
  }

  void _onDrop(DragTargetDetails<KanbanCard> details) {
    final index = _slotAt(details.offset);
    widget.dropSlot.value = null;
    unawaited(_controller.dropAt(details.data, widget.column, index));
  }

  // --- Клавиатура -------------------------------------------------------------

  KeyEventResult _onCardKey(KanbanCard card, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed) {
      final action = switch (key) {
        LogicalKeyboardKey.arrowLeft => _controller.shiftColumn(card, -1),
        LogicalKeyboardKey.arrowRight => _controller.shiftColumn(card, 1),
        LogicalKeyboardKey.arrowUp => _controller.shiftOrder(card, -1),
        LogicalKeyboardKey.arrowDown => _controller.shiftOrder(card, 1),
        _ => null,
      };
      if (action == null) return KeyEventResult.ignored;
      unawaited(action);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed) {
      unawaited(_controller.delete(card));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // --- Добавление -------------------------------------------------------------

  Future<void> _submitNew() async {
    final title = _newTitle.text.trim();
    if (title.isEmpty) return;
    final created =
        await _controller.create(title: title, column: widget.column);
    if (created != null && mounted) _newTitle.clear();
  }

  KeyEventResult _onAddFieldKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _newTitle.clear();
      widget.addFocusNode.unfocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // --- Сборка -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final colors = context.kanban;
    return Semantics(
      container: true,
      label: 'Колонка ${widget.column.label}',
      child: DragTarget<KanbanCard>(
        onWillAcceptWithDetails: (_) => true,
        onMove: _onDragMove,
        onLeave: _onDragLeave,
        onAcceptWithDetails: _onDrop,
        builder: (context, candidates, rejected) => Container(
          decoration: BoxDecoration(
            color: colors.column,
            borderRadius: BorderRadius.circular(16),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ColumnAccentBar(widget.column),
                _header(context),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: ValueListenableBuilder<DropSlot?>(
                      valueListenable: widget.dropSlot,
                      builder: (context, slot, _) => _cardList(
                        context,
                        slot?.column == widget.column ? slot!.index : null,
                        math.max(120, constraints.maxWidth - 16),
                      ),
                    ),
                  ),
                ),
                _addField(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(
          children: [
            ColumnIcon(widget.column),
            const SizedBox(width: 8),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  widget.column.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: context.kanban.text,
                  ),
                ),
              ),
            ),
            Semantics(
              label: tasksCount(widget.cards.length),
              excludeSemantics: true,
              child: CountBadge(widget.cards.length),
            ),
          ],
        ),
      );

  Widget _cardList(BuildContext context, int? activeSlot, double tileWidth) {
    final cards = widget.cards;
    if (cards.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _InsertionLine(active: activeSlot != null),
          EmptyColumnMessage(widget.column),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _InsertionLine(active: activeSlot == 0),
        for (var i = 0; i < cards.length; i++) ...[
          KeyedSubtree(
            key: widget.keyFor(cards[i].id),
            child: _draggableTile(context, cards[i], i, tileWidth),
          ),
          _InsertionLine(active: activeSlot == i + 1),
        ],
      ],
    );
  }

  Widget _draggableTile(
    BuildContext context,
    KanbanCard card,
    int index,
    double width,
  ) {
    final tile = CardTile(
      card: card,
      index: index,
      total: widget.cards.length,
      onTap: () => openCardEditor(context, ref, card: card, fullscreen: false),
      onKeyEvent: (_, event) => _onCardKey(card, event),
    );
    // Призрак под курсором: слегка повёрнут и с тенью.
    final feedback = Transform.translate(
      offset: Offset(-width / 2, -24),
      child: Transform.rotate(
        angle: 2 * math.pi / 180,
        child: SizedBox(
          width: width,
          child: Material(
            type: MaterialType.transparency,
            child: CardFace(card: card, elevated: true),
          ),
        ),
      ),
    );
    // На месте карточки остаётся пунктирный контур того же размера.
    final placeholder = CustomPaint(
      foregroundPainter: DashedBorderPainter(
        color: context.kanban.outline,
        strokeWidth: 2,
      ),
      child: Opacity(opacity: 0, child: CardFace(card: card)),
    );

    return _immediateDrag
        ? Draggable<KanbanCard>(
            data: card,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            feedback: feedback,
            childWhenDragging: placeholder,
            child: tile,
          )
        : LongPressDraggable<KanbanCard>(
            data: card,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            feedback: feedback,
            childWhenDragging: placeholder,
            child: tile,
          );
  }

  Widget _addField(BuildContext context) {
    final colors = context.kanban;
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.addFocusNode.requestFocus,
        child: ListenableBuilder(
          listenable: widget.addFocusNode,
          builder: (context, child) => CustomPaint(
            painter: DashedBorderPainter(
              color: widget.addFocusNode.hasFocus ? primary : colors.outline,
              strokeWidth: widget.addFocusNode.hasFocus ? 2 : 1,
            ),
            child: child,
          ),
          child: SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(Icons.add, size: 18, color: colors.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Focus(
                      canRequestFocus: false,
                      skipTraversal: true,
                      onKeyEvent: _onAddFieldKey,
                      child: Semantics(
                        label: 'Добавить задачу в «${widget.column.label}»',
                        child: TextField(
                          key: ValueKey('add-${widget.column.name}'),
                          controller: _newTitle,
                          focusNode: widget.addFocusNode,
                          maxLength: KanbanCard.maxTitleLength,
                          textCapitalization: TextCapitalization.sentences,
                          textInputAction: TextInputAction.done,
                          style: TextStyle(fontSize: 14, color: colors.text),
                          decoration: InputDecoration(
                            hintText: 'Добавить задачу',
                            hintStyle: TextStyle(
                              fontSize: 14,
                              color: colors.textSecondary,
                            ),
                            counterText: '',
                            isCollapsed: true,
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                          ),
                          // Enter сохраняет и оставляет фокус в поле —
                          // можно сразу вводить следующую задачу.
                          onEditingComplete: _submitNew,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Промежуток 8px между карточками; при перетаскивании в нём показывается
/// линия вставки 2px.
class _InsertionLine extends StatelessWidget {
  const _InsertionLine({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 8,
        child: active
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                child: DecoratedBox(
                  key: const ValueKey('insertion-line'),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              )
            : null,
      );
}

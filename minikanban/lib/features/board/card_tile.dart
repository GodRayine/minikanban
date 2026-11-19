/// Карточка задачи: внешний вид и интерактивная плитка.
library;

import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../domain/card.dart';
import 'board_text.dart';

/// Содержимое карточки без рамки и жестов: заголовок и до двух строк
/// описания. [compact] — плотный вариант для ПК (15/13), иначе
/// телефонный (16/14).
class CardContent extends StatelessWidget {
  const CardContent({super.key, required this.card, this.compact = true});

  final KanbanCard card;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.kanban;
    final done = card.column == BoardColumn.done;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          card.title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: compact ? 15 : 16,
            height: compact ? 20 / 15 : 22 / 16,
            fontWeight: FontWeight.w600,
            // Завершённые задачи приглушены, но остаются читаемыми.
            color: done ? colors.text.withValues(alpha: 0.7) : colors.text,
          ),
        ),
        if (card.description.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            card.description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact ? 13 : 14,
              height: compact ? 18 / 13 : 20 / 14,
              color: colors.textSecondary,
            ),
          ),
        ],
      ],
    );
  }
}

/// Неинтерактивная карточка с рамкой — «призрак» при перетаскивании.
class CardFace extends StatelessWidget {
  const CardFace({super.key, required this.card, this.elevated = false});

  final KanbanCard card;
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final colors = context.kanban;
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outline),
        boxShadow: [
          if (elevated)
            BoxShadow(
              color: colors.dragShadow,
              blurRadius: 28,
              offset: const Offset(0, 12),
            ),
        ],
      ),
      child: CardContent(card: card),
    );
  }
}

/// Интерактивная карточка: нажатие, долгое нажатие, наведение, фокус
/// с кольцом 2px и обработка клавиш.
class CardTile extends StatefulWidget {
  const CardTile({
    super.key,
    required this.card,
    required this.index,
    required this.total,
    required this.onTap,
    this.onLongPress,
    this.onKeyEvent,
    this.compact = true,
    this.trailing,
  });

  final KanbanCard card;

  /// Номер в колонке (с нуля) и размер колонки — для подписи диктора.
  final int index;
  final int total;

  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Клавиши, пока карточка в фокусе (перенос, удаление).
  final FocusOnKeyEventCallback? onKeyEvent;

  final bool compact;

  /// Виджет справа от содержимого (ручка перетаскивания на телефоне).
  final Widget? trailing;

  @override
  State<CardTile> createState() => _CardTileState();
}

class _CardTileState extends State<CardTile> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.kanban;
    final primary = Theme.of(context).colorScheme.primary;
    final active = _hovered || _focused;
    final radius = BorderRadius.circular(12);
    final trailing = widget.trailing;

    final content = Padding(
      padding: EdgeInsets.fromLTRB(16, 12, trailing == null ? 16 : 4, 12),
      child: CardContent(card: widget.card, compact: widget.compact),
    );

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: widget.onKeyEvent,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        constraints: const BoxConstraints(minHeight: 48),
        decoration: BoxDecoration(
          color: active ? colors.hover : colors.card,
          borderRadius: radius,
          border: Border.all(color: active ? primary : colors.outline),
          boxShadow: [
            // Кольцо фокуса: 2px цвета primary с отступом 2px от карточки.
            if (_focused) ...[
              BoxShadow(color: primary, spreadRadius: 4),
              BoxShadow(
                color: widget.compact ? colors.column : colors.background,
                spreadRadius: 2,
              ),
            ] else if (_hovered)
              const BoxShadow(
                color: Color(0x241B1C22),
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  label: cardSemanticsLabel(
                    widget.card,
                    widget.index,
                    widget.total,
                  ),
                  button: true,
                  excludeSemantics: true,
                  onTap: widget.onTap,
                  onLongPress: widget.onLongPress,
                  child: InkWell(
                    borderRadius: radius,
                    hoverColor: Colors.transparent,
                    focusColor: Colors.transparent,
                    onTap: widget.onTap,
                    onLongPress: widget.onLongPress,
                    onHover: (value) => setState(() => _hovered = value),
                    onFocusChange: (value) => setState(() => _focused = value),
                    child: content,
                  ),
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
        ),
      ),
    );
  }
}

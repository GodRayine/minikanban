/// Тексты интерфейса доски и мелкие виджеты оформления колонок.
library;

import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../domain/card.dart';

/// «1 задача», «2 задачи», «5 задач».
String tasksCount(int n) {
  final mod10 = n % 10;
  final mod100 = n % 100;
  final word = mod10 == 1 && mod100 != 11
      ? 'задача'
      : (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14))
          ? 'задачи'
          : 'задач';
  return '$n $word';
}

/// Текст пустого состояния колонки.
String emptyColumnText(BoardColumn column) => switch (column) {
      BoardColumn.todo => 'Здесь пока пусто. Добавьте первую задачу',
      BoardColumn.doing => 'Нет задач',
      BoardColumn.done => 'Пока ничего не завершено',
    };

/// Подпись карточки для экранных дикторов:
/// «Карточка „X“, колонка Y, 2 из 5».
String cardSemanticsLabel(KanbanCard card, int index, int total) =>
    'Карточка „${card.title}“, колонка ${card.column.label}, '
    '${index + 1} из $total';

/// «только что», «5 мин назад», «2 ч назад», «3 дн назад».
String relativeTime(DateTime moment, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(moment);
  if (diff.inMinutes < 1) return 'только что';
  if (diff.inHours < 1) return '${diff.inMinutes} мин назад';
  if (diff.inDays < 1) return '${diff.inHours} ч назад';
  return '${diff.inDays} дн назад';
}

/// Иконка колонки: ○ не начато, ◐ в процессе, ✓ готово. Колонка
/// различима не только цветом, но и формой значка.
class ColumnIcon extends StatelessWidget {
  const ColumnIcon(this.column, {super.key, this.size = 20, this.color});

  final BoardColumn column;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => Icon(
        switch (column) {
          BoardColumn.todo => Icons.radio_button_unchecked,
          BoardColumn.doing => Icons.contrast,
          BoardColumn.done => Icons.check_circle_outline,
        },
        size: size,
        color: color ?? context.kanban.accentInk(column),
      );
}

/// Цветная полоска 4px под верхним краем колонки.
class ColumnAccentBar extends StatelessWidget {
  const ColumnAccentBar(this.column, {super.key});

  final BoardColumn column;

  @override
  Widget build(BuildContext context) => Container(
        height: 4,
        margin: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: context.kanban.accent(column),
          borderRadius: const BorderRadius.vertical(bottom: Radius.circular(4)),
        ),
      );
}

/// Счётчик задач — «таблетка» с числом.
class CountBadge extends StatelessWidget {
  const CountBadge(
    this.count, {
    super.key,
    this.height = 24,
    this.background,
    this.foreground,
    this.bold = false,
  });

  final int count;
  final double height;
  final Color? background;
  final Color? foreground;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final colors = context.kanban;
    return Container(
      constraints: BoxConstraints(minWidth: height, minHeight: height),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background ?? colors.card,
        borderRadius: BorderRadius.circular(height / 2),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          fontSize: height >= 24 ? 13 : 12,
          height: 1,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
          color: foreground ?? colors.textSecondary,
        ),
      ),
    );
  }
}

/// Сообщение пустой колонки.
class EmptyColumnMessage extends StatelessWidget {
  const EmptyColumnMessage(this.column, {super.key});

  final BoardColumn column;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: Text(
          emptyColumnText(column),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 20 / 14,
            color: context.kanban.textSecondary,
          ),
        ),
      );
}

/// Пунктирная скруглённая рамка (поле «Добавить задачу», место
/// перетаскиваемой карточки).
class DashedBorderPainter extends CustomPainter {
  const DashedBorderPainter({
    required this.color,
    this.radius = 12,
    this.strokeWidth = 1,
    this.dash = 5,
    this.gap = 4,
  });

  final Color color;
  final double radius;
  final double strokeWidth;
  final double dash;
  final double gap;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    final rect = (Offset.zero & size).deflate(strokeWidth / 2);
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += dash + gap) {
        canvas.drawPath(metric.extractPath(d, d + dash), paint);
      }
    }
  }

  @override
  bool shouldRepaint(DashedBorderPainter old) =>
      old.color != color ||
      old.radius != radius ||
      old.strokeWidth != strokeWidth ||
      old.dash != dash ||
      old.gap != gap;
}

/// Узкий режим (телефон): вкладки-колонки со счётчиками, свайп карточки
/// в следующую колонку, bottom sheet «Переместить в…», FAB «+».
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../domain/board_repository.dart';
import '../../domain/card.dart';
import '../settings/sync_status_chip.dart';
import 'board_actions.dart';
import 'board_controller.dart';
import 'board_text.dart';
import 'card_editor.dart';
import 'card_tile.dart';

class NarrowBoard extends ConsumerStatefulWidget {
  const NarrowBoard({super.key, required this.board});

  final BoardSnapshot board;

  @override
  ConsumerState<NarrowBoard> createState() => _NarrowBoardState();
}

class _NarrowBoardState extends ConsumerState<NarrowBoard>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs =
      TabController(length: BoardColumn.values.length, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  BoardColumn get _currentColumn => BoardColumn.values[_tabs.index];

  @override
  Widget build(BuildContext context) {
    final colors = context.kanban;
    final primary = Theme.of(context).colorScheme.primary;
    final isHub = ref.watch(platformRoleProvider).isHub;
    final board = widget.board;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: const Text(
          'Мини-канбан',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Синхронизировать',
            onPressed: () => requestSync(context, ref),
            icon: const Icon(Icons.sync),
          ),
          if (isHub)
            IconButton(
              tooltip: 'Подключить телефон',
              onPressed: () => openPairing(context),
              icon: const Icon(Icons.smartphone),
            ),
          IconButton(
            tooltip: 'Настройки',
            onPressed: () => openSettings(context),
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48 + 49),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SyncStatusChip(
                    onTap: () => requestSync(context, ref),
                  ),
                ),
              ),
              TabBar(
                controller: _tabs,
                labelColor: primary,
                unselectedLabelColor: colors.textSecondary,
                labelStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                indicatorSize: TabBarIndicatorSize.label,
                indicator: UnderlineTabIndicator(
                  borderSide: BorderSide(color: primary, width: 3),
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(3)),
                ),
                dividerColor: colors.outline,
                tabs: [
                  for (final column in BoardColumn.values)
                    Tab(
                      height: 48,
                      child: _TabLabel(
                        column: column,
                        count: board.cards(column).length,
                        tabs: _tabs,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          for (final column in BoardColumn.values)
            _NarrowColumn(
              key: PageStorageKey(column),
              column: column,
              cards: board.cards(column),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Добавить задачу',
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        onPressed: () => openCardEditor(
          context,
          ref,
          initialColumn: _currentColumn,
          fullscreen: true,
        ),
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// Подпись вкладки: название колонки и счётчик задач.
class _TabLabel extends StatelessWidget {
  const _TabLabel({
    required this.column,
    required this.count,
    required this.tabs,
  });

  final BoardColumn column;
  final int count;
  final TabController tabs;

  @override
  Widget build(BuildContext context) {
    final colors = context.kanban;
    return Semantics(
      label: '${column.label}, ${tasksCount(count)}',
      excludeSemantics: true,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(column.label),
            const SizedBox(width: 6),
            ListenableBuilder(
              listenable: tabs,
              builder: (context, _) {
                final selected = tabs.index == column.index;
                return CountBadge(
                  count,
                  height: 20,
                  bold: selected,
                  background: selected ? colors.tonal : colors.column,
                  foreground: selected ? colors.onTonal : colors.textSecondary,
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Содержимое одной вкладки: список карточек колонки.
class _NarrowColumn extends ConsumerWidget {
  const _NarrowColumn({super.key, required this.column, required this.cards});

  final BoardColumn column;
  final List<KanbanCard> cards;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(boardControllerProvider);
    final colors = context.kanban;
    final next = BoardColumn.tryFromCode(column.code + 1);

    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ColumnAccentBar(column),
        Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 12),
          child: Row(
            children: [
              ColumnIcon(column),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${column.label} · ${tasksCount(cards.length)}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );

    const padding = EdgeInsets.fromLTRB(16, 0, 16, 96);
    const physics = AlwaysScrollableScrollPhysics();

    final Widget list;
    if (cards.isEmpty) {
      list = ListView(
        padding: padding,
        physics: physics,
        children: [
          header,
          const SizedBox(height: 32),
          EmptyColumnMessage(column),
        ],
      );
    } else {
      list = ReorderableListView.builder(
        padding: padding,
        physics: physics,
        buildDefaultDragHandles: false,
        header: header,
        footer: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Удерживайте карточку, чтобы переместить её в другую колонку.',
            style: TextStyle(
              fontSize: 13,
              height: 18 / 13,
              color: colors.textSecondary,
            ),
          ),
        ),
        proxyDecorator: (child, index, animation) => Material(
          type: MaterialType.transparency,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: colors.dragShadow,
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: child,
          ),
        ),
        itemCount: cards.length,
        onReorderItem: (oldIndex, newIndex) =>
            unawaited(controller.reorder(column, oldIndex, newIndex)),
        itemBuilder: (context, index) {
          final card = cards[index];
          return Padding(
            key: ValueKey(card.id),
            padding: const EdgeInsets.only(bottom: 8),
            child: _SwipeToNext(
              card: card,
              next: next,
              onSwiped: () => controller.moveToColumn(card, next!),
              child: CardTile(
                card: card,
                index: index,
                total: cards.length,
                compact: false,
                onTap: () =>
                    openCardEditor(context, ref, card: card, fullscreen: true),
                onLongPress: () => _showCardSheet(context, ref, card),
                trailing: ReorderableDragStartListener(
                  index: index,
                  child: Semantics(
                    label: 'Перетащить задачу «${card.title}»',
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Icon(
                        Icons.drag_indicator,
                        size: 20,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    }

    return RefreshIndicator(onRefresh: () => refreshSync(ref), child: list);
  }
}

/// Свайп карточки вправо — перенос в следующую колонку. В последней
/// колонке свайп отключён.
class _SwipeToNext extends StatelessWidget {
  const _SwipeToNext({
    required this.card,
    required this.next,
    required this.onSwiped,
    required this.child,
  });

  final KanbanCard card;
  final BoardColumn? next;
  final Future<void> Function() onSwiped;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final target = next;
    if (target == null) return child;
    final colors = context.kanban;
    return Dismissible(
      key: ValueKey('swipe-${card.id}'),
      direction: DismissDirection.startToEnd,
      // Карточку из списка убирает обновление доски, а не Dismissible:
      // так отмена возвращает её без рассинхронизации со списком.
      confirmDismiss: (_) async {
        await onSwiped();
        return false;
      },
      background: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: colors.tonal,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.arrow_forward, size: 20, color: colors.onTonal),
            const SizedBox(width: 8),
            Text(
              target.label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: colors.onTonal,
              ),
            ),
          ],
        ),
      ),
      child: child,
    );
  }
}

// --- Bottom sheet «Переместить в…» ------------------------------------------

sealed class _SheetAction {
  const _SheetAction();
}

final class _MoveTo extends _SheetAction {
  const _MoveTo(this.column);
  final BoardColumn column;
}

final class _Edit extends _SheetAction {
  const _Edit();
}

final class _Delete extends _SheetAction {
  const _Delete();
}

Future<void> _showCardSheet(
  BuildContext context,
  WidgetRef ref,
  KanbanCard card,
) async {
  final controller = ref.read(boardControllerProvider);
  final action = await showModalBottomSheet<_SheetAction>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _CardSheet(card: card),
  );
  switch (action) {
    case null:
      return;
    case _MoveTo(:final column):
      await controller.moveToColumn(card, column);
    case _Edit():
      if (context.mounted) {
        await openCardEditor(context, ref, card: card, fullscreen: true);
      }
    case _Delete():
      await controller.delete(card);
  }
}

class _CardSheet extends StatelessWidget {
  const _CardSheet({required this.card});

  final KanbanCard card;

  @override
  Widget build(BuildContext context) {
    final colors = context.kanban;
    final error = Theme.of(context).colorScheme.error;
    void close(_SheetAction action) => Navigator.of(context).pop(action);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    card.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 20,
                      height: 26 / 20,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                      color: colors.text,
                    ),
                  ),
                  if (card.description.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      card.description,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        height: 20 / 14,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
              child: Text(
                'Переместить в:',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colors.textSecondary,
                ),
              ),
            ),
            for (final column in BoardColumn.values)
              _SheetRow(
                icon: ColumnIcon(
                  column,
                  size: 24,
                  color: column == card.column ? colors.onTonal : null,
                ),
                label: column.label,
                current: column == card.column,
                onTap:
                    column == card.column ? null : () => close(_MoveTo(column)),
              ),
            const Divider(height: 17),
            _SheetRow(
              icon: Icon(Icons.edit_outlined, color: colors.text),
              label: 'Изменить',
              onTap: () => close(const _Edit()),
            ),
            _SheetRow(
              icon: Icon(Icons.delete_outline, color: error),
              label: 'Удалить',
              color: error,
              onTap: () => close(const _Delete()),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.current = false,
    this.color,
  });

  final Widget icon;
  final String label;
  final VoidCallback? onTap;

  /// Колонка, в которой карточка уже находится: строка выделена и
  /// неактивна.
  final bool current;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.kanban;
    final foreground = current ? colors.onTonal : (color ?? colors.text);
    return Semantics(
      button: true,
      enabled: onTap != null,
      selected: current,
      child: Material(
        color: current ? colors.tonal : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  icon,
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: current ? FontWeight.w600 : FontWeight.w500,
                        color: foreground,
                      ),
                    ),
                  ),
                  if (current) ...[
                    Text(
                      'Сейчас здесь',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: foreground,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.check, size: 20, color: foreground),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

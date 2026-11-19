/// Главный экран: доска. По ширине выбирает три колонки (ПК, планшет)
/// или вкладки (телефон).
library;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../domain/board_repository.dart';
import '../../domain/card.dart';
import '../settings/sync_status_chip.dart';
import 'board_actions.dart';
import 'column_view.dart';
import 'narrow_board.dart';

/// С этой ширины показываются три колонки рядом.
const double wideLayoutBreakpoint = 840;

class BoardPage extends ConsumerWidget {
  const BoardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final board = ref.watch(boardProvider);
    final wide = MediaQuery.sizeOf(context).width >= wideLayoutBreakpoint;

    return board.when(
      skipLoadingOnReload: true,
      data: (snapshot) =>
          wide ? WideBoard(board: snapshot) : NarrowBoard(board: snapshot),
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Не удалось открыть доску.\n$error',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}

/// Широкий режим: шапка и три колонки по ~320px.
class WideBoard extends ConsumerStatefulWidget {
  const WideBoard({super.key, required this.board});

  final BoardSnapshot board;

  @override
  ConsumerState<WideBoard> createState() => _WideBoardState();
}

class _WideBoardState extends ConsumerState<WideBoard> {
  final Map<String, GlobalKey> _cardKeys = {};
  final ValueNotifier<DropSlot?> _dropSlot = ValueNotifier(null);
  final Map<BoardColumn, FocusNode> _addNodes = {
    for (final c in BoardColumn.values)
      c: FocusNode(debugLabel: 'add-${c.name}'),
  };
  ModalRoute<Object?>? _route;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onGlobalKey);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    _dropSlot.dispose();
    for (final node in _addNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  GlobalKey _keyFor(String cardId) =>
      _cardKeys.putIfAbsent(cardId, () => GlobalKey(debugLabel: cardId));

  /// Клавиша N — новая задача: фокус в поле «Добавить задачу» колонки
  /// «Не начато». Не срабатывает во время ввода текста и под диалогами.
  bool _onGlobalKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.keyN &&
        event.physicalKey != PhysicalKeyboardKey.keyN) {
      return false;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return false;
    }
    if (!mounted || !(_route?.isCurrent ?? true)) return false;
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return false;
    }
    _addNodes[BoardColumn.todo]!.requestFocus();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final board = widget.board;
    final live = {
      for (final column in BoardColumn.values)
        for (final card in board.cards(column)) card.id,
    };
    _cardKeys.removeWhere((id, _) => !live.contains(id));

    final width = MediaQuery.sizeOf(context).width;
    final roomy = width >= 1120;
    final gap = roomy ? 24.0 : 16.0;

    return Scaffold(
      body: Column(
        children: [
          _WideHeader(compact: width < 1040),
          Expanded(
            child: SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.all(roomy ? 32 : 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final column in BoardColumn.values) ...[
                      if (column != BoardColumn.values.first)
                        SizedBox(width: gap),
                      Flexible(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 320),
                          child: ColumnView(
                            key: ValueKey(column),
                            column: column,
                            cards: board.cards(column),
                            keyFor: _keyFor,
                            dropSlot: _dropSlot,
                            addFocusNode: _addNodes[column]!,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Шапка широкого режима: название, чип статуса, кнопки.
class _WideHeader extends ConsumerWidget {
  const _WideHeader({required this.compact});

  /// Узкое окно: «Синхронизировать» сворачивается в иконку.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.kanban;
    final primary = Theme.of(context).colorScheme.primary;
    final isHub = ref.watch(platformRoleProvider).isHub;
    void sync() => requestSync(context, ref);

    return Container(
      decoration: BoxDecoration(
        color: colors.card,
        border: Border(bottom: BorderSide(color: colors.outline)),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 72,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 32),
            child: Row(
              children: [
                Icon(Icons.view_kanban_outlined, size: 28, color: primary),
                const SizedBox(width: 16),
                Semantics(
                  header: true,
                  child: Text(
                    'Мини-канбан',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                      color: colors.text,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: SyncStatusChip(onTap: sync),
                  ),
                ),
                const SizedBox(width: 12),
                if (compact)
                  IconButton(
                    tooltip: 'Синхронизировать',
                    onPressed: sync,
                    icon: const Icon(Icons.sync),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: sync,
                    icon: const Icon(Icons.sync, size: 20),
                    label: const Text('Синхронизировать'),
                  ),
                const SizedBox(width: 12),
                if (isHub)
                  FilledButton.icon(
                    onPressed: () => openPairing(context),
                    icon: const Icon(Icons.smartphone, size: 20),
                    label: const Text('Подключить телефон'),
                  ),
                if (isHub) const SizedBox(width: 4),
                if (isHub)
                  IconButton(
                    tooltip: 'Настройки',
                    onPressed: () => openSettings(context),
                    icon: const Icon(Icons.settings_outlined),
                  )
                else
                  IconButton(
                    tooltip: 'Настройки',
                    onPressed: () => openSettings(context),
                    icon: const Icon(Icons.settings_outlined),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

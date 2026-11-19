/// Редактор задачи: диалог 560px на широком экране и полноэкранная
/// страница на телефоне. Используется и для создания, и для правки.
library;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../domain/card.dart';
import 'board_controller.dart';
import 'board_text.dart';

/// Итог работы редактора.
sealed class CardEditorResult {
  const CardEditorResult();
}

final class CardEditorSaved extends CardEditorResult {
  const CardEditorSaved({
    required this.title,
    required this.description,
    required this.column,
  });

  final String title;
  final String description;
  final BoardColumn column;
}

final class CardEditorDeleted extends CardEditorResult {
  const CardEditorDeleted();
}

/// Открывает редактор и применяет результат через [BoardController].
///
/// [card] == `null` — создание новой задачи в [initialColumn].
/// [fullscreen] — полноэкранная страница вместо диалога.
Future<void> openCardEditor(
  BuildContext context,
  WidgetRef ref, {
  KanbanCard? card,
  BoardColumn initialColumn = BoardColumn.todo,
  required bool fullscreen,
}) async {
  final controller = ref.read(boardControllerProvider);
  final editor = CardEditor(
    card: card,
    initialColumn: initialColumn,
    fullscreen: fullscreen,
  );
  final result = fullscreen
      ? await Navigator.of(context).push<CardEditorResult>(
          MaterialPageRoute(fullscreenDialog: true, builder: (_) => editor),
        )
      : await showDialog<CardEditorResult>(
          context: context,
          builder: (_) => editor,
        );

  switch (result) {
    case null:
      return;
    case CardEditorDeleted():
      if (card != null) await controller.delete(card);
    case CardEditorSaved(:final title, :final description, :final column):
      if (card == null) {
        await controller.create(
          title: title,
          description: description,
          column: column,
        );
      } else {
        await controller.saveEdits(
          card,
          title: title,
          description: description,
          column: column,
        );
      }
  }
}

class CardEditor extends StatefulWidget {
  const CardEditor({
    super.key,
    this.card,
    this.initialColumn = BoardColumn.todo,
    required this.fullscreen,
  });

  final KanbanCard? card;
  final BoardColumn initialColumn;
  final bool fullscreen;

  @override
  State<CardEditor> createState() => _CardEditorState();
}

class _CardEditorState extends State<CardEditor> {
  late final TextEditingController _title =
      TextEditingController(text: widget.card?.title ?? '');
  late final TextEditingController _description =
      TextEditingController(text: widget.card?.description ?? '');
  late BoardColumn _column = widget.card?.column ?? widget.initialColumn;
  String? _titleError;
  String? _descriptionError;

  bool get _isNew => widget.card == null;

  String get _heading => _isNew ? 'Новая задача' : 'Редактировать задачу';

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  void _save() {
    final titleError = KanbanCard.titleError(_title.text);
    final descriptionError = KanbanCard.descriptionError(_description.text);
    if (titleError != null || descriptionError != null) {
      setState(() {
        _titleError = titleError;
        _descriptionError = descriptionError;
      });
      return;
    }
    Navigator.of(context).pop<CardEditorResult>(
      CardEditorSaved(
        title: _title.text.trim(),
        description: _description.text,
        column: _column,
      ),
    );
  }

  void _delete() =>
      Navigator.of(context).pop<CardEditorResult>(const CardEditorDeleted());

  void _cancel() => Navigator.of(context).pop<CardEditorResult>();

  @override
  Widget build(BuildContext context) {
    final body = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _save,
      },
      child: widget.fullscreen ? _buildPage(context) : _buildDialog(context),
    );
    return body;
  }

  // --- Диалог (широкий экран) -------------------------------------------------

  Widget _buildDialog(BuildContext context) {
    final colors = context.kanban;
    final error = Theme.of(context).colorScheme.error;
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _heading,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.2,
                        color: colors.text,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Закрыть',
                    onPressed: _cancel,
                    icon: Icon(Icons.close, color: colors.textSecondary),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              ..._fields(context, descriptionLines: 4),
              const SizedBox(height: 24),
              Row(
                children: [
                  if (!_isNew)
                    TextButton.icon(
                      onPressed: _delete,
                      style: TextButton.styleFrom(foregroundColor: error),
                      icon: const Icon(Icons.delete_outline, size: 20),
                      label: const Text('Удалить'),
                    ),
                  const Spacer(),
                  TextButton(onPressed: _cancel, child: const Text('Отмена')),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _save,
                    child: const Text('Сохранить'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Полноэкранная страница (телефон) -------------------------------------

  Widget _buildPage(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return Scaffold(
      backgroundColor: context.kanban.card,
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Закрыть',
          onPressed: _cancel,
          icon: const Icon(Icons.close),
        ),
        title: Text(_heading),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _save,
              child: const Text('Сохранить'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            ..._fields(context, descriptionLines: 6),
            if (!_isNew) ...[
              const SizedBox(height: 24),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _delete,
                  style: TextButton.styleFrom(foregroundColor: error),
                  icon: const Icon(Icons.delete_outline, size: 20),
                  label: const Text('Удалить'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // --- Общие поля -----------------------------------------------------------

  List<Widget> _fields(BuildContext context, {required int descriptionLines}) {
    const fieldStyle = TextStyle(fontSize: 15, height: 22 / 15);
    return [
      const _FieldLabel('Название задачи'),
      TextField(
        key: const ValueKey('editor-title'),
        controller: _title,
        autofocus: true,
        style: fieldStyle,
        maxLength: KanbanCard.maxTitleLength,
        textCapitalization: TextCapitalization.sentences,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          counterText: '',
          errorText: _titleError,
          hintText: 'Что нужно сделать?',
        ),
        onChanged: (_) {
          if (_titleError != null) setState(() => _titleError = null);
        },
        onSubmitted: (_) => _save(),
      ),
      const SizedBox(height: 20),
      const _FieldLabel('Описание (необязательно)'),
      TextField(
        key: const ValueKey('editor-description'),
        controller: _description,
        style: fieldStyle,
        minLines: descriptionLines,
        maxLines: descriptionLines + 4,
        maxLength: KanbanCard.maxDescriptionLength,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          counterText: '',
          errorText: _descriptionError,
        ),
        onChanged: (_) {
          if (_descriptionError != null) {
            setState(() => _descriptionError = null);
          }
        },
      ),
      const SizedBox(height: 20),
      const _FieldLabel('Колонка'),
      SegmentedButton<BoardColumn>(
        showSelectedIcon: false,
        style: SegmentedButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        segments: [
          for (final column in BoardColumn.values)
            ButtonSegment(
              value: column,
              // На телефоне три подписи с иконками не помещаются в ширину.
              icon: widget.fullscreen ? null : ColumnIcon(column, size: 18),
              label: Text(column.label, maxLines: 1, softWrap: false),
            ),
        ],
        selected: {_column},
        onSelectionChanged: (value) => setState(() => _column = value.single),
      ),
    ];
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: context.kanban.textSecondary,
          ),
        ),
      );
}

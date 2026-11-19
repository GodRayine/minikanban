import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:minikanban/app/app.dart';
import 'package:minikanban/app/providers.dart';
import 'package:minikanban/core/platform_role.dart';
import 'package:minikanban/domain/card.dart';
import 'package:minikanban/features/board/board_text.dart';
import 'package:minikanban/features/board/card_tile.dart';
import 'package:minikanban/features/board/column_view.dart';
import 'package:minikanban/features/pairing/pair_pc_page.dart';
import 'package:minikanban/features/settings/settings_page.dart';
import 'package:minikanban/features/settings/sync_status_chip.dart';
import 'package:minikanban/sync/sync_status.dart';

import '../support/fake_board_repository.dart';

const wideSize = Size(1280, 800);
const narrowSize = Size(412, 915);

Future<void> pumpApp(
  WidgetTester tester,
  FakeBoardRepository repo, {
  required Size size,
  PlatformRole role = PlatformRole.hub,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        boardRepositoryProvider.overrideWithValue(repo),
        platformRoleProvider.overrideWithValue(role),
      ],
      child: const MiniKanbanApp(),
    ),
  );
  await tester.pumpAndSettle();
}

/// Колонка широкого режима.
Finder columnOf(BoardColumn column) => find.byKey(ValueKey(column));

Finder inColumn(BoardColumn column, Finder matching) =>
    find.descendant(of: columnOf(column), matching: matching);

Future<void> pressWithControl(
    WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

void focusCard(WidgetTester tester, String title) =>
    Focus.of(tester.element(find.text(title))).requestFocus();

void main() {
  late FakeBoardRepository repo;

  setUp(() => repo = FakeBoardRepository());

  group('тексты', () {
    test('склонение числа задач', () {
      expect(tasksCount(0), '0 задач');
      expect(tasksCount(1), '1 задача');
      expect(tasksCount(2), '2 задачи');
      expect(tasksCount(5), '5 задач');
      expect(tasksCount(11), '11 задач');
      expect(tasksCount(21), '21 задача');
      expect(tasksCount(112), '112 задач');
    });

    test('относительное время', () {
      final now = DateTime(2026, 1, 1, 12);
      String ago(Duration d) => relativeTime(now.subtract(d), now: now);
      expect(ago(const Duration(seconds: 20)), 'только что');
      expect(ago(const Duration(minutes: 2)), '2 мин назад');
      expect(ago(const Duration(hours: 3)), '3 ч назад');
      expect(ago(const Duration(days: 2)), '2 дн назад');
    });

    test('подписи чипа синхронизации', () {
      final now = DateTime(2026, 1, 1, 12);
      expect(
        syncStatusLabel(
          SyncStatus(
            SyncPhase.synced,
            lastSyncAt: now.subtract(const Duration(minutes: 2)),
          ),
          PlatformRole.client,
          now: now,
        ),
        'Синхронизировано · 2 мин назад',
      );
      expect(
        syncStatusLabel(const SyncStatus(SyncPhase.syncing), PlatformRole.hub),
        'Синхронизация…',
      );
      expect(
        syncStatusLabel(
          const SyncStatus(SyncPhase.offline),
          PlatformRole.client,
        ),
        'Нет связи с ПК',
      );
      expect(
        syncStatusLabel(
            const SyncStatus(SyncPhase.notPaired), PlatformRole.hub),
        'Телефон не подключён',
      );
    });
  });

  group('широкий режим', () {
    testWidgets('три колонки, шапка ПК, без вкладок', (tester) async {
      await repo.create(title: 'Купить молоко', description: 'И хлеб');
      await repo.create(title: 'Отчёт', column: BoardColumn.doing);
      await pumpApp(tester, repo, size: wideSize);

      expect(find.byType(ColumnView), findsNWidgets(3));
      expect(find.byType(TabBar), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
      for (final column in BoardColumn.values) {
        expect(inColumn(column, find.text(column.label)), findsOneWidget);
      }
      expect(
        inColumn(BoardColumn.todo, find.text('Купить молоко')),
        findsOneWidget,
      );
      expect(inColumn(BoardColumn.todo, find.text('И хлеб')), findsOneWidget);
      expect(inColumn(BoardColumn.doing, find.text('Отчёт')), findsOneWidget);
      expect(tester.getSize(columnOf(BoardColumn.todo)).width, 320);

      expect(find.text('Мини-канбан'), findsOneWidget);
      expect(find.text('Телефон не подключён'), findsOneWidget);
      expect(find.text('Синхронизировать'), findsOneWidget);
      expect(find.text('Подключить телефон'), findsOneWidget);
    });

    testWidgets('«Подключить телефон» и чип ведут на экран подключения',
        (tester) async {
      await pumpApp(tester, repo, size: wideSize);

      await tester.tap(find.text('Подключить телефон'));
      await tester.pumpAndSettle();
      expect(find.byType(PairPcPage), findsOneWidget);

      await tester.tap(find.byTooltip('Назад'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SyncStatusChip));
      await tester.pumpAndSettle();
      expect(find.byType(PairPcPage), findsOneWidget);
    });

    testWidgets('пустые состояния в каждой колонке', (tester) async {
      await pumpApp(tester, repo, size: wideSize);

      expect(
        inColumn(
          BoardColumn.todo,
          find.text('Здесь пока пусто. Добавьте первую задачу'),
        ),
        findsOneWidget,
      );
      expect(
          inColumn(BoardColumn.doing, find.text('Нет задач')), findsOneWidget);
      expect(
        inColumn(BoardColumn.done, find.text('Пока ничего не завершено')),
        findsOneWidget,
      );
    });

    testWidgets('поле «Добавить задачу»: Enter сохраняет, Esc отменяет',
        (tester) async {
      await pumpApp(tester, repo, size: wideSize);
      final field = find.byKey(const ValueKey('add-doing'));

      await tester.enterText(field, '  Новая задача ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(repo.titles(BoardColumn.doing), ['Новая задача']);
      expect(
        inColumn(BoardColumn.doing, find.byType(CardTile)),
        findsOneWidget,
      );
      expect(inColumn(BoardColumn.doing, find.text('Нет задач')), findsNothing);
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      // Фокус остаётся в поле — можно вводить следующую задачу.
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);

      await tester.enterText(field, 'Черновик');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isFalse);
      expect(repo.titles(BoardColumn.doing), ['Новая задача']);
    });

    testWidgets('диалог: правка текста и колонки', (tester) async {
      await repo.create(title: 'Старое');
      await pumpApp(tester, repo, size: wideSize);

      await tester.tap(find.text('Старое'));
      await tester.pumpAndSettle();
      expect(find.text('Редактировать задачу'), findsOneWidget);
      expect(tester.getSize(find.byType(Dialog)).width, greaterThan(0));

      await tester.enterText(
        find.byKey(const ValueKey('editor-title')),
        'Новое',
      );
      await tester.enterText(
        find.byKey(const ValueKey('editor-description')),
        'Описание',
      );
      await tester.tap(
        find.descendant(
          of: find.byType(SegmentedButton<BoardColumn>),
          matching: find.text('Готово'),
        ),
      );
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();

      expect(find.text('Редактировать задачу'), findsNothing);
      expect(repo.titles(BoardColumn.todo), isEmpty);
      final card = repo.byTitle('Новое');
      expect(card.column, BoardColumn.done);
      expect(card.description, 'Описание');
      expect(inColumn(BoardColumn.done, find.text('Новое')), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('диалог не сохраняет пустое название', (tester) async {
      await repo.create(title: 'Задача');
      await pumpApp(tester, repo, size: wideSize);

      await tester.tap(find.text('Задача'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('editor-title')), '  ');
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();

      expect(find.text('Введите заголовок'), findsOneWidget);
      expect(find.text('Редактировать задачу'), findsOneWidget);
      expect(repo.titles(BoardColumn.todo), ['Задача']);
    });

    testWidgets('удаление из диалога и отмена через SnackBar', (tester) async {
      await repo.create(title: 'A');
      await repo.create(title: 'B');
      await pumpApp(tester, repo, size: wideSize);

      await tester.tap(find.text('A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить'));
      await tester.pumpAndSettle();

      expect(repo.titles(BoardColumn.todo), ['B']);
      expect(find.text('Задача удалена'), findsOneWidget);

      await tester.tap(find.text('Отменить'));
      await tester.pumpAndSettle();
      expect(repo.titles(BoardColumn.todo), ['A', 'B']);
      expect(inColumn(BoardColumn.todo, find.text('A')), findsOneWidget);
    });

    testWidgets('SnackBar отмены исчезает через 6 секунд', (tester) async {
      await repo.create(title: 'A');
      await pumpApp(tester, repo, size: wideSize);

      focusCard(tester, 'A');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Задача удалена'), findsOneWidget);
      expect(repo.titles(BoardColumn.todo), isEmpty);

      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.text('Задача удалена'), findsNothing);
    });

    testWidgets('клавиатура: Ctrl+стрелки переносят и меняют порядок',
        (tester) async {
      await repo.create(title: 'A');
      await repo.create(title: 'B');
      await repo.create(title: 'C');
      await pumpApp(tester, repo, size: wideSize);

      focusCard(tester, 'A');
      await tester.pump();

      await pressWithControl(tester, LogicalKeyboardKey.arrowDown);
      expect(repo.titles(BoardColumn.todo), ['B', 'A', 'C']);
      await pressWithControl(tester, LogicalKeyboardKey.arrowDown);
      expect(repo.titles(BoardColumn.todo), ['B', 'C', 'A']);
      await pressWithControl(tester, LogicalKeyboardKey.arrowDown);
      expect(repo.titles(BoardColumn.todo), ['B', 'C', 'A']);
      await pressWithControl(tester, LogicalKeyboardKey.arrowUp);
      expect(repo.titles(BoardColumn.todo), ['B', 'A', 'C']);

      // Фокус переезжает вместе с карточкой, поэтому нажатия подряд
      // продолжают двигать её же.
      await pressWithControl(tester, LogicalKeyboardKey.arrowRight);
      expect(repo.titles(BoardColumn.doing), ['A']);
      await pressWithControl(tester, LogicalKeyboardKey.arrowRight);
      expect(repo.titles(BoardColumn.done), ['A']);
      await pressWithControl(tester, LogicalKeyboardKey.arrowRight);
      expect(repo.titles(BoardColumn.done), ['A']);
      await pressWithControl(tester, LogicalKeyboardKey.arrowLeft);
      expect(repo.titles(BoardColumn.doing), ['A']);
      expect(repo.titles(BoardColumn.todo), ['B', 'C']);
    });

    testWidgets('клавиатура: Enter открывает, N — новая задача',
        (tester) async {
      await repo.create(title: 'A');
      await pumpApp(tester, repo, size: wideSize);

      focusCard(tester, 'A');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Редактировать задачу'), findsOneWidget);

      // Под диалогом N не перехватывается.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Редактировать задачу'), findsNothing);

      final field = find.byKey(const ValueKey('add-todo'));
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
    });

    testWidgets('перетаскивание между колонками с линией вставки',
        (tester) async {
      await repo.create(title: 'A');
      await repo.create(title: 'X', column: BoardColumn.doing);
      await repo.create(title: 'Y', column: BoardColumn.doing);
      await pumpApp(tester, repo, size: wideSize);

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('A')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      // Между X и Y: чуть ниже середины X.
      final target = tester.getCenter(find.text('X')) + const Offset(0, 20);
      await gesture.moveTo(target);
      await tester.pump();
      expect(
        inColumn(
          BoardColumn.doing,
          find.byKey(const ValueKey('insertion-line')),
        ),
        findsOneWidget,
      );

      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('insertion-line')), findsNothing);
      expect(repo.titles(BoardColumn.todo), isEmpty);
      expect(repo.titles(BoardColumn.doing), ['X', 'A', 'Y']);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('перетаскивание внутри колонки', (tester) async {
      await repo.create(title: 'A');
      await repo.create(title: 'B');
      await repo.create(title: 'C');
      await pumpApp(tester, repo, size: wideSize);

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('C')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump();
      await gesture.moveTo(
        tester.getCenter(find.text('A').first) - const Offset(0, 15),
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(repo.titles(BoardColumn.todo), ['C', 'A', 'B']);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('подписи карточек для экранного диктора', (tester) async {
      final handle = tester.ensureSemantics();
      await repo.create(title: 'A');
      await repo.create(title: 'B');
      await pumpApp(tester, repo, size: wideSize);

      expect(
        find.bySemanticsLabel('Карточка „B“, колонка Не начато, 2 из 2'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp('Добавить задачу в «Готово»')),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('карточки и кнопки не меньше 48dp по высоте', (tester) async {
      await repo.create(title: 'A');
      await pumpApp(tester, repo, size: wideSize);

      expect(
        tester.getSize(find.byType(CardTile)).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('sync-chip'))).height,
        greaterThanOrEqualTo(48),
      );
    });
  });

  group('узкий режим', () {
    testWidgets('вкладки со счётчиками, FAB, без колонок рядом',
        (tester) async {
      await repo.create(title: 'A');
      await repo.create(title: 'B');
      await repo.create(title: 'C', column: BoardColumn.done);
      await pumpApp(tester, repo, size: narrowSize, role: PlatformRole.client);

      expect(find.byType(TabBar), findsOneWidget);
      expect(find.byType(ColumnView), findsNothing);
      expect(find.byType(FloatingActionButton), findsOneWidget);
      for (final column in BoardColumn.values) {
        expect(
          find.descendant(
            of: find.byType(TabBar),
            matching: find.text(column.label),
          ),
          findsOneWidget,
        );
      }
      final badges = tester
          .widgetList<CountBadge>(
            find.descendant(
              of: find.byType(TabBar),
              matching: find.byType(CountBadge),
            ),
          )
          .map((b) => b.count);
      expect(badges, [2, 0, 1]);
      expect(find.text('Не начато · 2 задачи'), findsOneWidget);
      expect(find.text('Не подключено к ПК'), findsOneWidget);
      expect(find.byTooltip('Настройки'), findsOneWidget);
      expect(find.text('Подключить телефон'), findsNothing);

      // Переход на вкладку «Готово».
      await tester.tap(
        find.descendant(of: find.byType(TabBar), matching: find.text('Готово')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Готово · 1 задача'), findsOneWidget);
      expect(find.text('C'), findsOneWidget);
    });

    testWidgets('иконка настроек открывает настройки', (tester) async {
      await pumpApp(tester, repo, size: narrowSize, role: PlatformRole.client);
      await tester.tap(find.byTooltip('Настройки'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);
    });

    testWidgets('пустые состояния на вкладках', (tester) async {
      await pumpApp(tester, repo, size: narrowSize, role: PlatformRole.client);
      expect(
        find.text('Здесь пока пусто. Добавьте первую задачу'),
        findsOneWidget,
      );

      await tester.tap(
        find.descendant(
          of: find.byType(TabBar),
          matching: find.text('В процессе'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Нет задач'), findsOneWidget);

      await tester.tap(
        find.descendant(of: find.byType(TabBar), matching: find.text('Готово')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Пока ничего не завершено'), findsOneWidget);
    });

    testWidgets('FAB открывает полноэкранный редактор и создаёт карточку',
        (tester) async {
      await pumpApp(tester, repo, size: narrowSize, role: PlatformRole.client);

      await tester.tap(
        find.descendant(
          of: find.byType(TabBar),
          matching: find.text('В процессе'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.text('Новая задача'), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('Удалить'), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('editor-title')),
        'С телефона',
      );
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();

      // Колонка по умолчанию — открытая вкладка.
      expect(repo.titles(BoardColumn.doing), ['С телефона']);
      expect(find.text('Новая задача'), findsNothing);
      expect(find.text('С телефона'), findsOneWidget);
      expect(find.text('В процессе · 1 задача'), findsOneWidget);
    });

    testWidgets('долгое нажатие: bottom sheet «Переместить в»', (tester) async {
      await repo.create(title: 'A');
      await repo.create(title: 'B');
      await pumpApp(tester, repo, size: narrowSize, role: PlatformRole.client);

      await tester.longPress(find.text('A'));
      await tester.pumpAndSettle();

      expect(find.text('Переместить в:'), findsOneWidget);
      expect(find.text('Сейчас здесь'), findsOneWidget);
      expect(find.text('Изменить'), findsOneWidget);
      expect(find.text('Удалить'), findsOneWidget);

      // Текущая колонка неактивна.
      final current = find.ancestor(
        of: find.text('Сейчас здесь'),
        matching: find.byType(InkWell),
      );
      expect(tester.widget<InkWell>(current.first).onTap, isNull);

      await tester.tap(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('Готово'),
        ),
      );
      await tester.pumpAndSettle();

      expect(repo.titles(BoardColumn.todo), ['B']);
      expect(repo.titles(BoardColumn.done), ['A']);
      expect(find.text('Задача перемещена в „Готово“'), findsOneWidget);

      // Отмена возвращает карточку на прежнее место — перед B.
      await tester.tap(find.text('Отменить'));
      await tester.pumpAndSettle();
      expect(repo.titles(BoardColumn.todo), ['A', 'B']);
      expect(repo.titles(BoardColumn.done), isEmpty);
    });

    testWidgets('bottom sheet: удаление с отменой', (tester) async {
      await repo.create(title: 'A');
      await pumpApp(tester, repo, size: narrowSize, role: PlatformRole.client);

      await tester.longPress(find.text('A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить'));
      await tester.pumpAndSettle();

      expect(repo.titles(BoardColumn.todo), isEmpty);
      expect(find.text('Задача удалена'), findsOneWidget);
      await tester.tap(find.text('Отменить'));
      await tester.pumpAndSettle();
      expect(repo.titles(BoardColumn.todo), ['A']);
    });

    testWidgets('свайп вправо переносит в следующую колонку', (tester) async {
      await repo.create(title: 'A');
      await pumpApp(tester, repo, size: narrowSize, role: PlatformRole.client);

      await tester.fling(find.text('A'), const Offset(300, 0), 1000);
      await tester.pumpAndSettle();

      expect(repo.titles(BoardColumn.todo), isEmpty);
      expect(repo.titles(BoardColumn.doing), ['A']);
      expect(find.text('Задача перемещена в „В процессе“'), findsOneWidget);
      expect(find.text('Не начато · 0 задач'), findsOneWidget);
    });

    testWidgets('ручка перетаскивания меняет порядок в колонке',
        (tester) async {
      await repo.create(title: 'A');
      await repo.create(title: 'B');
      await repo.create(title: 'C');
      await pumpApp(tester, repo, size: narrowSize, role: PlatformRole.client);

      await tester.timedDrag(
        find.byIcon(Icons.drag_indicator).first,
        const Offset(0, 200),
        const Duration(milliseconds: 600),
      );
      await tester.pumpAndSettle();

      expect(repo.titles(BoardColumn.todo), ['B', 'C', 'A']);
    });

    testWidgets('нажатие открывает редактор с кнопкой «Удалить»',
        (tester) async {
      await repo.create(title: 'A', description: 'текст');
      await pumpApp(tester, repo, size: narrowSize, role: PlatformRole.client);

      await tester.tap(find.text('A'));
      await tester.pumpAndSettle();
      expect(find.text('Редактировать задачу'), findsOneWidget);
      expect(find.text('Удалить'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('editor-title')),
        'A2',
      );
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(repo.titles(BoardColumn.todo), ['A2']);
      expect(repo.byTitle('A2').description, 'текст');
    });
  });

  testWidgets('тёмная тема системы применяется', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await pumpApp(tester, repo, size: wideSize);

    final context = tester.element(find.byType(ColumnView).first);
    expect(Theme.of(context).brightness, Brightness.dark);
  });
}

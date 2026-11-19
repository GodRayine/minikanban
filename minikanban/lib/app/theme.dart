/// Тема приложения: Material 3, seed индиго, светлая и тёмная.
library;

import 'package:material_ui/material_ui.dart';

import '../domain/card.dart';

const Color _seed = Color(0xFF3F51B5);

/// Цвета макета, которых нет в [ColorScheme].
@immutable
class KanbanColors extends ThemeExtension<KanbanColors> {
  const KanbanColors({
    required this.background,
    required this.card,
    required this.column,
    required this.text,
    required this.textSecondary,
    required this.outline,
    required this.hover,
    required this.tonal,
    required this.onTonal,
    required this.slate,
    required this.amber,
    required this.amberInk,
    required this.green,
    required this.syncedBg,
    required this.syncedFg,
    required this.warnBg,
    required this.warnFg,
    required this.dragShadow,
  });

  /// Фон окна.
  final Color background;

  /// Поверхность карточек, шапки, диалогов.
  final Color card;

  /// Фон колонки и счётчиков.
  final Color column;
  final Color text;
  final Color textSecondary;
  final Color outline;

  /// Фон карточки под курсором / в фокусе.
  final Color hover;
  final Color tonal;
  final Color onTonal;

  /// Акцент «Не начато».
  final Color slate;

  /// Акцент «В процессе»: полоска.
  final Color amber;

  /// Акцент «В процессе»: иконка и текст (контрастнее полоски).
  final Color amberInk;

  /// Акцент «Готово».
  final Color green;

  final Color syncedBg;
  final Color syncedFg;
  final Color warnBg;
  final Color warnFg;
  final Color dragShadow;

  static const KanbanColors light = KanbanColors(
    background: Color(0xFFF4F5FA),
    card: Color(0xFFFFFFFF),
    column: Color(0xFFE9EBF3),
    text: Color(0xFF1B1C22),
    textSecondary: Color(0xFF4A4D5A),
    outline: Color(0xFFC3C6D2),
    hover: Color(0xFFF3F4FB),
    tonal: Color(0xFFE0E3FA),
    onTonal: Color(0xFF1F2A6B),
    slate: Color(0xFF5B6B82),
    amber: Color(0xFFD48A0C),
    amberInk: Color(0xFF8A5200),
    green: Color(0xFF2E7D4F),
    syncedBg: Color(0xFFDDEFE3),
    syncedFg: Color(0xFF1E5C38),
    warnBg: Color(0xFFFCEBC8),
    warnFg: Color(0xFF6B4300),
    dragShadow: Color(0x471B1C22),
  );

  static const KanbanColors dark = KanbanColors(
    background: Color(0xFF121318),
    card: Color(0xFF272A34),
    column: Color(0xFF1B1D25),
    text: Color(0xFFE4E5EC),
    textSecondary: Color(0xFFB7BAC8),
    outline: Color(0xFF4A4D5A),
    hover: Color(0xFF2F3340),
    tonal: Color(0xFF2C3566),
    onTonal: Color(0xFFDDE1FF),
    slate: Color(0xFF9FB0C8),
    amber: Color(0xFFE8A93A),
    amberInk: Color(0xFFF0BC5E),
    green: Color(0xFF7FCF9D),
    syncedBg: Color(0xFF1F3A2A),
    syncedFg: Color(0xFFA6E0BC),
    warnBg: Color(0xFF4A3A12),
    warnFg: Color(0xFFF3D38C),
    dragShadow: Color(0x99000000),
  );

  /// Цвет полоски-акцента колонки.
  Color accent(BoardColumn column) => switch (column) {
        BoardColumn.todo => slate,
        BoardColumn.doing => amber,
        BoardColumn.done => green,
      };

  /// Цвет иконки колонки (достаточно контрастный для мелких деталей).
  Color accentInk(BoardColumn column) => switch (column) {
        BoardColumn.todo => slate,
        BoardColumn.doing => amberInk,
        BoardColumn.done => green,
      };

  @override
  KanbanColors copyWith() => this;

  @override
  KanbanColors lerp(KanbanColors? other, double t) =>
      other == null || t < 0.5 ? this : other;
}

extension KanbanTheme on BuildContext {
  KanbanColors get kanban => Theme.of(this).extension<KanbanColors>()!;
}

ThemeData buildTheme(Brightness brightness) {
  final colors =
      brightness == Brightness.dark ? KanbanColors.dark : KanbanColors.light;
  final primary = brightness == Brightness.dark
      ? const Color(0xFFB5BEFA)
      : const Color(0xFF3F51B5);
  final onPrimary = brightness == Brightness.dark
      ? const Color(0xFF1B2466)
      : const Color(0xFFFFFFFF);
  final scheme = ColorScheme.fromSeed(
    seedColor: _seed,
    brightness: brightness,
  ).copyWith(
    primary: primary,
    onPrimary: onPrimary,
    surface: colors.card,
    onSurface: colors.text,
    onSurfaceVariant: colors.textSecondary,
    outline: colors.outline,
    outlineVariant: colors.outline,
    secondaryContainer: colors.tonal,
    onSecondaryContainer: colors.onTonal,
  );

  OutlineInputBorder inputBorder(Color color, double width) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: color, width: width),
      );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: colors.background,
    extensions: [colors],
    // Обычная «рябь» на всех платформах: на Android по умолчанию был бы
    // InkSparkle, которому нужен отдельный шейдер.
    splashFactory: InkRipple.splashFactory,
    appBarTheme: AppBarThemeData(
      backgroundColor: colors.card,
      foregroundColor: colors.text,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
    ),
    dividerTheme: DividerThemeData(color: colors.outline, thickness: 1),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colors.card,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: colors.outline,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: colors.card,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: inputBorder(colors.outline, 1),
      enabledBorder: inputBorder(colors.outline, 1),
      focusedBorder: inputBorder(primary, 2),
      errorBorder: inputBorder(scheme.error, 1),
      focusedErrorBorder: inputBorder(scheme.error, 2),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        side: BorderSide(color: colors.outline),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: primary,
      foregroundColor: onPrimary,
    ),
  );
}

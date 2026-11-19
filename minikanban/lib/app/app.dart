/// Корневой виджет приложения.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../features/board/board_controller.dart';
import '../features/board/board_page.dart';
import '../features/pairing/onboarding_page.dart';
import 'bootstrap.dart';
import 'theme.dart';

class MiniKanbanApp extends ConsumerWidget {
  const MiniKanbanApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
        title: 'Мини-канбан',
        debugShowCheckedModeBanner: false,
        scaffoldMessengerKey: ref.watch(scaffoldMessengerKeyProvider),
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: ThemeMode.system,
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: const _Home(),
      );
}

/// Доска; на непривязанном телефоне при первом запуске поверх неё
/// показывается приветственный экран.
class _Home extends ConsumerStatefulWidget {
  const _Home();

  @override
  ConsumerState<_Home> createState() => _HomeState();
}

class _HomeState extends ConsumerState<_Home> {
  @override
  void initState() {
    super.initState();
    if (!ref.read(onboardingNeededProvider)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            fullscreenDialog: true,
            builder: (_) => const OnboardingPage(),
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const BoardPage();
}

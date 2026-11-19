/// Приветственный экран на телефоне, пока он не привязан к компьютеру.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/bootstrap.dart';
import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/meta_dao.dart';
import 'scan_page.dart';

class OnboardingPage extends ConsumerWidget {
  const OnboardingPage({super.key});

  /// Больше не показывать экран при запуске.
  static Future<void> _markDone(WidgetRef ref) async {
    try {
      await MetaDao(ref.read(databaseProvider)).set(onboardingDoneKey, '1');
    } on Object {
      // Нет БД (тесты) — экран просто покажется ещё раз.
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.kanban;
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.view_kanban_outlined, size: 72, color: primary),
                const SizedBox(height: 24),
                Text(
                  'Подключите телефон к компьютеру',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 24,
                    height: 30 / 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                    color: colors.text,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Задачи будут одинаковыми на обоих устройствах. Откройте '
                  '«Мини-канбан» на компьютере, нажмите «Подключить телефон» '
                  'и отсканируйте QR-код.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    height: 22 / 15,
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 32),
                FilledButton.icon(
                  onPressed: () async {
                    await _markDone(ref);
                    if (!context.mounted) return;
                    await openScanPage(context);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Сканировать QR-код'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(240, 48),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    unawaited(_markDone(ref));
                    Navigator.of(context).pop();
                  },
                  child: const Text('Позже'),
                ),
                const SizedBox(height: 8),
                Text(
                  'Приложением можно пользоваться и без компьютера — '
                  'подключиться можно позже в настройках.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: colors.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

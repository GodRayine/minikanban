/// Действия шапки, общие для широкого и узкого режимов: синхронизация,
/// переходы на экраны подключения и настроек.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/providers.dart';
import '../../sync/sync_status.dart';
import '../pairing/pair_pc_page.dart';
import '../pairing/scan_page.dart';
import '../settings/settings_page.dart';
import 'board_controller.dart';

Future<void> openPairing(BuildContext context) => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const PairPcPage()),
    );

Future<void> openSettings(BuildContext context) => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
    );

/// Ручная синхронизация (чип, кнопка). Без привязки подсказывает, что
/// сначала нужно связать устройства: на ПК открывает экран подключения.
Future<void> requestSync(BuildContext context, WidgetRef ref) async {
  final phase = ref.read(syncStatusProvider).phase;
  final isHub = ref.read(platformRoleProvider).isHub;
  if (phase == SyncPhase.notPaired) {
    if (isHub) {
      await openPairing(context);
    } else if (ref.read(pairingClientProvider) != null) {
      await openScanPage(context);
    } else {
      ref
          .read(boardControllerProvider)
          .notify('Сначала подключите телефон к компьютеру');
    }
    return;
  }
  if (phase == SyncPhase.revoked || phase == SyncPhase.certError) {
    // Нужна новая привязка — причина и кнопка есть в настройках.
    await openSettings(context);
    return;
  }
  await ref.read(syncStatusProvider.notifier).syncNow();
  if (isHub) {
    ref.read(boardControllerProvider).notify(
          'Телефон синхронизируется сам, когда приложение на нём открыто',
        );
  }
}

/// Pull-to-refresh: синхронизация без переходов на другие экраны.
Future<void> refreshSync(WidgetRef ref) async {
  final phase = ref.read(syncStatusProvider).phase;
  if (phase == SyncPhase.notPaired) {
    ref.read(boardControllerProvider).notify('Синхронизация ещё не настроена');
    return;
  }
  if (phase == SyncPhase.revoked) {
    ref
        .read(boardControllerProvider)
        .notify('Телефон отвязан от компьютера — подключите его заново');
    return;
  }
  await ref.read(syncStatusProvider.notifier).syncNow();
}

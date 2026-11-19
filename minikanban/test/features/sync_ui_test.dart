import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:minikanban/app/app.dart';
import 'package:minikanban/app/providers.dart';
import 'package:minikanban/core/platform_role.dart';
import 'package:minikanban/data/device_dao.dart';
import 'package:minikanban/features/pairing/pair_pc_page.dart';
import 'package:minikanban/features/settings/settings_page.dart';
import 'package:minikanban/features/settings/sync_status_chip.dart';
import 'package:minikanban/sync/sync_status.dart';

import '../support/fake_board_repository.dart';

Future<void> pumpApp(
  WidgetTester tester, {
  required Size size,
  required PlatformRole role,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        boardRepositoryProvider.overrideWithValue(FakeBoardRepository()),
        platformRoleProvider.overrideWithValue(role),
      ],
      child: const MiniKanbanApp(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('обратный отсчёт срока действия кода', () {
    expect(formatCountdown(const Duration(minutes: 4, seconds: 59)), '4:59');
    expect(formatCountdown(const Duration(seconds: 61)), '1:01');
    expect(formatCountdown(const Duration(seconds: 9)), '0:09');
    expect(formatCountdown(Duration.zero), '0:00');
    expect(formatCountdown(const Duration(seconds: -5)), '0:00');
  });

  test('время последней синхронизации телефона на ПК', () {
    final now = DateTime(2026, 1, 1, 12);
    PairedDevice device(int? lastSyncAt) => PairedDevice(
          deviceId: 'd',
          name: 'Pixel 9',
          platform: 'android',
          tokenHash: 'h',
          pairedAt: 0,
          lastSyncAt: lastSyncAt,
        );
    expect(deviceSyncLabel(device(null)), 'Ещё не синхронизировался');
    expect(
      deviceSyncLabel(
        device(now.subtract(const Duration(minutes: 3)).millisecondsSinceEpoch),
        now: now,
      ),
      'Синхронизация 3 мин назад',
    );
    expect(
      deviceSyncLabel(
        device(now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch),
        now: now,
      ),
      'Синхронизация 2 ч назад',
    );
  });

  test('подписи чипа для новых состояний', () {
    String label(SyncPhase phase, PlatformRole role) =>
        syncStatusLabel(SyncStatus(phase), role);
    expect(label(SyncPhase.revoked, PlatformRole.client), 'Отвязано от ПК');
    expect(
      label(SyncPhase.certError, PlatformRole.client),
      'Ошибка сертификата ПК',
    );
    expect(
      label(SyncPhase.incompatible, PlatformRole.client),
      'Несовместимая версия',
    );
    expect(label(SyncPhase.synced, PlatformRole.hub), 'Телефон подключён');
    expect(label(SyncPhase.synced, PlatformRole.client), 'Синхронизировано');
    expect(SyncPhase.notPaired.isPaired, isFalse);
    expect(SyncPhase.revoked.isPaired, isTrue);
    expect(SyncPhase.revoked.isBlocked, isTrue);
    expect(SyncPhase.offline.isBlocked, isFalse);
  });

  testWidgets('ПК: экран подключения без сервера объясняет причину',
      (tester) async {
    await pumpApp(tester, size: const Size(1280, 800), role: PlatformRole.hub);
    await tester.tap(find.text('Подключить телефон'));
    await tester.pumpAndSettle();

    expect(find.byType(PairPcPage), findsOneWidget);
    expect(find.text('Синхронизация недоступна'), findsOneWidget);
  });

  testWidgets('ПК: настройки с автозапуском и треем', (tester) async {
    await pumpApp(tester, size: const Size(1280, 800), role: PlatformRole.hub);
    await tester.tap(find.byTooltip('Настройки'));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.text('Запускать вместе с Windows'), findsOneWidget);
    expect(find.text('Закрытие окна сворачивает в трей'), findsOneWidget);
    // Без оболочки рабочего стола (тест) переключатель выключен и неактивен.
    final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(toggle.value, isFalse);
    expect(toggle.onChanged, isNull);
  });

  testWidgets('телефон: настройки без привязки', (tester) async {
    await pumpApp(
      tester,
      size: const Size(412, 915),
      role: PlatformRole.client,
    );
    await tester.tap(find.byTooltip('Настройки'));
    await tester.pumpAndSettle();

    expect(find.text('Подключение к компьютеру'), findsOneWidget);
    expect(find.text('Не подключено к ПК'), findsOneWidget);
    expect(find.text('Отвязать'), findsNothing);
  });
}

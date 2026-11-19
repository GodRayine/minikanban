/// Запуск служб синхронизации: сервер на ПК, клиент на телефоне.
library;

import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../data/board_repository_impl.dart';
import '../data/meta_dao.dart';
import '../sync/client/background_sync.dart';
import '../sync/client/client_store.dart';
import '../sync/client/nsd_discovery.dart';
import '../sync/client/pairing_client.dart';
import '../sync/client/sync_client.dart';
import '../sync/client/sync_scheduler.dart';
import '../sync/server/cert_service.dart';
import '../sync/server/nsd_advertiser.dart';
import '../sync/server/sync_server.dart';
import 'desktop_shell.dart';
import 'providers.dart';

/// Ключ `meta`: приветственный экран на телефоне уже показан.
const String onboardingDoneKey = 'onboarding_done';

/// Телефон: показать при запуске приветственный экран с предложением
/// подключиться к компьютеру.
final onboardingNeededProvider = Provider<bool>((ref) => false);

/// ПК: трей, сертификат, HTTPS-сервер, объявление в сети.
///
/// Сбой любой части не мешает работе доски: сервер может не запуститься
/// (экран подключения покажет причину), трей — не появиться.
Future<List<Override>> startHubServices(
  Database db,
  BoardRepositoryImpl repository,
) async {
  final shell = await DesktopShell.init();
  final advertiser = NsdAdvertiser();
  SyncServer? server;
  String? error;
  try {
    final identity =
        await CertService(await getApplicationSupportDirectory()).loadOrCreate();
    server = SyncServer(
      db: db,
      repository: repository,
      identity: identity,
      serverName: Platform.localHostname,
    );
    await server.start();
    unawaited(
      advertiser.start(
        serverId: server.serverId,
        serverName: server.serverName,
        port: server.port,
      ),
    );
  } on Object catch (e, stack) {
    debugPrint('Сервер синхронизации не запущен: $e\n$stack');
    error = '$e';
    server = null;
  }
  final running = server;
  shell?.onQuit = () async {
    await advertiser.stop();
    await running?.stop();
  };
  return [
    syncServerProvider.overrideWithValue(server),
    syncServerErrorProvider.overrideWithValue(error),
    desktopShellProvider.overrideWithValue(shell),
  ];
}

Future<String> _androidDeviceName() async {
  final info = await DeviceInfoPlugin().androidInfo;
  final model = info.model.trim();
  final brand = info.manufacturer.trim();
  if (model.isEmpty) return brand.isEmpty ? 'Телефон' : brand;
  if (brand.isEmpty || model.toLowerCase().startsWith(brand.toLowerCase())) {
    return model;
  }
  return '$brand $model';
}

/// Телефон: клиент синхронизации, расписание, фоновая задача.
Future<List<Override>> startClientServices(
  Database db,
  BoardRepositoryImpl repository,
) async {
  final store = ClientStore(db, const SecureTokenStore());
  final client = SyncClient(
    db: db,
    repository: repository,
    store: store,
    discover: discoverMiniKanban,
  );
  var onboardingNeeded = false;
  try {
    await client.reload();
    onboardingNeeded = !client.status.value.phase.isPaired &&
        await MetaDao(db).get(onboardingDoneKey) == null;
  } on Object catch (error) {
    debugPrint('Не удалось прочитать привязку: $error');
  }

  final scheduler = SyncScheduler(
    sync: client.sync,
    localChanges: repository.localChanges,
    onForeground: () async {
      // Пока приложение было свёрнуто, БД могла изменить фоновая задача.
      await repository.refresh();
      await client.reload();
    },
  )..start();

  final pairing = PairingClient(
    db: db,
    repository: repository,
    store: store,
    deviceName: _androidDeviceName,
    discover: discoverMiniKanban,
  );

  if (Platform.isAndroid) unawaited(registerBackgroundSync());

  return [
    syncClientProvider.overrideWithValue(client),
    syncSchedulerProvider.overrideWithValue(scheduler),
    pairingClientProvider.overrideWithValue(pairing),
    onboardingNeededProvider.overrideWithValue(onboardingNeeded),
  ];
}

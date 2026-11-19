/// Фоновая синхронизация на Android: WorkManager раз в 15 минут (чаще
/// система не разрешает), только при наличии сети.
library;

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../../core/platform_role.dart';
import '../../data/board_repository_impl.dart';
import '../../data/db.dart';
import 'client_store.dart';
import 'nsd_discovery.dart';
import 'sync_client.dart';

const String _uniqueName = 'minikanban.periodicSync';
const String _taskName = 'minikanbanSync';

/// Точка входа фонового изолята WorkManager.
@pragma('vm:entry-point')
void backgroundSyncDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      final result = await runBackgroundSync();
      debugPrint('Фоновая синхронизация: ${result.name}');
    } on Object catch (error) {
      debugPrint('Фоновая синхронизация не удалась: $error');
    }
    // Всегда «успех»: следующий запуск и так будет по расписанию, а
    // повтор с бэкоффом WorkManager при выключенном ПК только тратит заряд.
    return true;
  });
}

/// Один обмен с ПК в собственном соединении с БД.
Future<SyncResult> runBackgroundSync() async {
  final db = await openAppDatabase();
  final repository =
      await BoardRepositoryImpl.open(db, role: PlatformRole.client);
  final client = SyncClient(
    db: db,
    repository: repository,
    store: ClientStore(db, const SecureTokenStore()),
    discover: discoverMiniKanban,
  );
  try {
    return await client.sync();
  } finally {
    client.dispose();
    await repository.dispose();
    // БД не закрываем: на Android соединение по этому пути общее с
    // основным изолятом, если приложение сейчас открыто.
  }
}

/// Регистрирует периодическую задачу (повторный вызов ничего не ломает).
/// Возвращает `false`, если WorkManager недоступен.
Future<bool> registerBackgroundSync() async {
  try {
    await Workmanager().initialize(backgroundSyncDispatcher);
    await Workmanager().registerPeriodicTask(
      _uniqueName,
      _taskName,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
    return true;
  } on Object catch (error) {
    debugPrint('WorkManager: не удалось запланировать синхронизацию: $error');
    return false;
  }
}

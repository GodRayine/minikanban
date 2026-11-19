/// Корневые провайдеры приложения: БД, роль устройства, репозиторий, доска,
/// службы синхронизации.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../core/platform_role.dart';
import '../domain/board_repository.dart';
import '../sync/client/pairing_client.dart';
import '../sync/client/sync_client.dart';
import '../sync/client/sync_scheduler.dart';
import '../sync/server/sync_server.dart';
import 'desktop_shell.dart';

/// Открытая БД. Подменяется в `main()` после инициализации.
final databaseProvider = Provider<Database>(
  (ref) => throw UnimplementedError('databaseProvider не инициализирован'),
);

/// Роль устройства (хаб/клиент). В тестах подменяется.
final platformRoleProvider = Provider<PlatformRole>(
  (ref) => detectPlatformRole(),
);

/// Хранилище доски. Подменяется в `main()` (SQLite) и в тестах (fake).
final boardRepositoryProvider = Provider<BoardRepository>(
  (ref) =>
      throw UnimplementedError('boardRepositoryProvider не инициализирован'),
);

/// Текущий снимок доски; обновляется после каждой записи.
final boardProvider = StreamProvider<BoardSnapshot>(
  (ref) => ref.watch(boardRepositoryProvider).watchBoard(),
);

// --- Синхронизация ----------------------------------------------------------
// Службы создаются в `main()`; по умолчанию их нет (виджет-тесты, сбой
// запуска сервера) — интерфейс обязан работать и без них.

/// ПК: сервер синхронизации или `null`, если он не запущен.
final syncServerProvider = Provider<SyncServer?>((ref) => null);

/// ПК: почему сервер не запустился (для экрана подключения).
final syncServerErrorProvider = Provider<String?>((ref) => null);

/// ПК: окно, трей и автозапуск.
final desktopShellProvider = Provider<DesktopShell?>((ref) => null);

/// Телефон: клиент синхронизации.
final syncClientProvider = Provider<SyncClient?>((ref) => null);

/// Телефон: расписание синхронизации.
final syncSchedulerProvider = Provider<SyncScheduler?>((ref) => null);

/// Телефон: привязка к ПК.
final pairingClientProvider = Provider<PairingClient?>((ref) => null);

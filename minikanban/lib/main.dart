import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'app/app.dart';
import 'app/bootstrap.dart';
import 'app/providers.dart';
import 'app/theme.dart';
import 'core/platform_role.dart';
import 'data/board_repository_impl.dart';
import 'data/db.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final role = detectPlatformRole();

  try {
    final db = await openAppDatabase();
    final repository = await BoardRepositoryImpl.open(db, role: role);
    final syncOverrides = role.isHub
        ? await startHubServices(db, repository)
        : await startClientServices(db, repository);
    runApp(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          platformRoleProvider.overrideWithValue(role),
          boardRepositoryProvider.overrideWithValue(repository),
          ...syncOverrides,
        ],
        child: const MiniKanbanApp(),
      ),
    );
  } on Object catch (error) {
    // Без БД работать нельзя: показываем причину вместо пустого окна.
    runApp(_StartupErrorApp(error: error));
  }
}

class _StartupErrorApp extends StatelessWidget {
  const _StartupErrorApp({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Мини-канбан',
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 48),
                  const SizedBox(height: 16),
                  const Text(
                    'Не удалось открыть базу данных',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  SelectableText('$error', textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
        ),
      );
}

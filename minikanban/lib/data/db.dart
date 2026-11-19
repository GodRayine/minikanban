/// Открытие SQLite и миграции схемы.
///
/// Версия схемы хранится в `PRAGMA user_version`; миграции применяются
/// последовательно в одной транзакции, поэтому БД либо остаётся на старой
/// версии, либо целиком переходит на новую.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as mobile;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Имя файла БД в каталоге данных приложения.
const String databaseFileName = 'minikanban.db';

/// Одна миграция: переводит схему с версии `index` на `index + 1`.
typedef Migration = Future<void> Function(Transaction txn);

/// Миграции по порядку. Новые добавляются ТОЛЬКО в конец списка;
/// уже выпущенные не редактируются.
const List<Migration> migrations = [_v1];

/// Актуальная версия схемы.
int get schemaVersion => migrations.length;

/// Фабрика БД для текущей платформы: FFI на настольных ОС, плагин
/// `sqflite` на Android/iOS.
DatabaseFactory platformDatabaseFactory() {
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
    sqfliteFfiInit();
    return databaseFactoryFfi;
  }
  // Явно берём фабрику плагина: глобальная databaseFactory задаётся
  // при регистрации плагина и может быть ещё не установлена.
  return mobile.databaseFactorySqflitePlugin;
}

/// Путь к файлу БД в каталоге поддержки приложения (создаёт каталог).
Future<String> defaultDatabasePath() async {
  final dir = await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  return p.join(dir.path, databaseFileName);
}

/// Открывает БД и доводит схему до [schemaVersion].
///
/// [path] по умолчанию — [defaultDatabasePath]; для тестов можно передать
/// [inMemoryDatabasePath]. [factory] по умолчанию —
/// [platformDatabaseFactory]. [upTo] ограничивает число применяемых
/// миграций (только для тестов миграций).
///
/// Бросает [StateError], если файл создан более новой версией приложения.
Future<Database> openAppDatabase({
  String? path,
  DatabaseFactory? factory,
  @visibleForTesting int? upTo,
}) async {
  final dbFactory = factory ?? platformDatabaseFactory();
  final dbPath = path ?? await defaultDatabasePath();
  final db = await dbFactory.openDatabase(
    dbPath,
    options: OpenDatabaseOptions(
      // У каждой in-memory БД должно быть своё соединение.
      singleInstance: dbPath != inMemoryDatabasePath,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    ),
  );
  try {
    await _migrate(db, upTo ?? schemaVersion);
  } catch (_) {
    await db.close();
    rethrow;
  }
  return db;
}

Future<void> _migrate(Database db, int target) async {
  final current = await db.getVersion();
  if (current > schemaVersion) {
    throw StateError(
      'База данных версии $current создана более новой версией приложения '
      '(поддерживается до $schemaVersion)',
    );
  }
  if (current >= target) return;
  await db.transaction((txn) async {
    for (var version = current; version < target; version++) {
      await migrations[version](txn);
    }
    await txn.execute('PRAGMA user_version = $target');
  });
}

/// v1: исходная схема (PLAN.md §4).
Future<void> _v1(Transaction txn) async {
  await txn.execute('''
    CREATE TABLE cards (
      id TEXT PRIMARY KEY NOT NULL,
      title TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '',
      "column" INTEGER NOT NULL DEFAULT 0 CHECK ("column" BETWEEN 0 AND 2),
      pos TEXT NOT NULL,
      deleted INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL DEFAULT 0,
      hlc_title TEXT NOT NULL,
      hlc_description TEXT NOT NULL,
      hlc_column TEXT NOT NULL,
      hlc_pos TEXT NOT NULL,
      hlc_deleted TEXT NOT NULL,
      server_seq INTEGER NOT NULL DEFAULT 0
    )
  ''');
  await txn.execute(
    'CREATE INDEX idx_cards_column ON cards ("column", deleted, pos)',
  );
  await txn.execute('CREATE INDEX idx_cards_server_seq ON cards (server_seq)');

  // Клиент: локальные правки, ещё не подтверждённые хабом.
  await txn.execute('''
    CREATE TABLE outbox (
      change_id TEXT PRIMARY KEY NOT NULL,
      card_id TEXT NOT NULL,
      fields_json TEXT NOT NULL,
      hlc_json TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''');
  await txn.execute('CREATE INDEX idx_outbox_created ON outbox (created_at)');

  // Хаб: уже применённые изменения клиентов (идемпотентность повторов).
  await txn.execute('''
    CREATE TABLE applied_changes (
      change_id TEXT PRIMARY KEY NOT NULL,
      applied_at INTEGER NOT NULL
    )
  ''');
  await txn.execute(
    'CREATE INDEX idx_applied_changes_at ON applied_changes (applied_at)',
  );

  // Хаб: привязанные телефоны.
  await txn.execute('''
    CREATE TABLE devices (
      device_id TEXT PRIMARY KEY NOT NULL,
      name TEXT NOT NULL,
      platform TEXT NOT NULL,
      token_hash TEXT NOT NULL,
      paired_at INTEGER NOT NULL,
      last_sync_at INTEGER,
      revoked INTEGER NOT NULL DEFAULT 0
    )
  ''');

  await txn.execute('''
    CREATE TABLE meta (
      key TEXT PRIMARY KEY NOT NULL,
      value TEXT NOT NULL
    )
  ''');
}

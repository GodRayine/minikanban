/// Журналы изменений: `outbox` (клиент) и `applied_changes` (хаб).
library;

import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import '../sync/protocol/dto.dart';

/// Очередь локальных правок клиента, ожидающих отправки на хаб.
class OutboxDao {
  const OutboxDao(this._db);

  final DatabaseExecutor _db;

  static const String table = 'outbox';

  /// Добавляет изменение в очередь. Повтор с тем же `change_id` игнорируется.
  Future<void> add(CardChange change, {required int createdAt}) async {
    final json = change.toJson();
    await _db.insert(
      table,
      {
        'change_id': change.changeId,
        'card_id': change.id,
        'fields_json': jsonEncode(json['fields']),
        'hlc_json': jsonEncode(json['hlc']),
        'created_at': createdAt,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Изменения в порядке создания (самые старые первыми).
  Future<List<CardChange>> pending({int? limit}) async {
    final rows = await _db.query(
      table,
      orderBy: 'created_at, rowid',
      limit: limit,
    );
    return rows.map(_fromRow).toList();
  }

  /// Удаляет подтверждённые хабом изменения.
  Future<void> remove(Iterable<String> changeIds) async {
    final batch = _db.batch();
    for (final id in changeIds) {
      batch.delete(table, where: 'change_id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  /// Полностью очищает очередь (полный reset после 410).
  Future<void> clear() => _db.delete(table);

  Future<int> count() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS n FROM $table');
    return rows.first['n']! as int;
  }

  static CardChange _fromRow(Map<String, Object?> row) => CardChange.fromJson({
        'change_id': row['change_id'],
        'entity': cardEntity,
        'id': row['card_id'],
        'fields': jsonDecode(row['fields_json']! as String),
        'hlc': jsonDecode(row['hlc_json']! as String),
      });
}

/// Идентификаторы изменений, уже применённых хабом: повторная доставка
/// того же `change_id` подтверждается без повторной обработки.
class AppliedChangesDao {
  const AppliedChangesDao(this._db);

  final DatabaseExecutor _db;

  static const String table = 'applied_changes';

  Future<bool> contains(String changeId) async {
    final rows = await _db.query(
      table,
      columns: const ['change_id'],
      where: 'change_id = ?',
      whereArgs: [changeId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> add(String changeId, {required int appliedAt}) => _db.insert(
        table,
        {'change_id': changeId, 'applied_at': appliedAt},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );

  /// Удаляет записи старше [before] (мс эпохи); возвращает их число.
  Future<int> purgeOlderThan(int before) =>
      _db.delete(table, where: 'applied_at < ?', whereArgs: [before]);

  Future<int> count() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS n FROM $table');
    return rows.first['n']! as int;
  }
}

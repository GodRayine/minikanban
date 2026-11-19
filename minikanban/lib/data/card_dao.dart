/// Доступ к таблице `cards`.
library;

import 'package:sqflite_common/sqlite_api.dart';

import '../core/hlc.dart';
import '../domain/card.dart';

/// DAO карточек. Принимает [DatabaseExecutor], поэтому работает и с БД,
/// и внутри транзакции.
class CardDao {
  const CardDao(this._db);

  final DatabaseExecutor _db;

  static const String table = 'cards';

  /// Карточка по id (включая удалённые) или `null`.
  Future<KanbanCard?> getById(String id) async {
    final rows = await _db.query(table, where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : fromRow(rows.first);
  }

  /// Все неудалённые карточки в порядке `(column, pos, id)`.
  Future<List<KanbanCard>> active() async {
    final rows = await _db.query(
      table,
      where: 'deleted = 0',
      orderBy: '"column", pos, id',
    );
    return rows.map(fromRow).toList();
  }

  /// Неудалённые карточки колонки сверху вниз.
  Future<List<KanbanCard>> activeInColumn(BoardColumn column) async {
    final rows = await _db.query(
      table,
      where: '"column" = ? AND deleted = 0',
      whereArgs: [column.code],
      orderBy: 'pos, id',
    );
    return rows.map(fromRow).toList();
  }

  /// Наибольший ключ порядка среди неудалённых карточек колонки.
  Future<String?> lastPos(BoardColumn column) async {
    final rows = await _db.rawQuery(
      'SELECT MAX(pos) AS pos FROM $table WHERE "column" = ? AND deleted = 0',
      [column.code],
    );
    return rows.first['pos'] as String?;
  }

  /// Карточки (включая tombstone) с `server_seq > seq` по возрастанию —
  /// выдача изменений клиенту на хабе.
  Future<List<KanbanCard>> changedSince(int seq, {int limit = 500}) async {
    final rows = await _db.query(
      table,
      where: 'server_seq > ?',
      whereArgs: [seq],
      orderBy: 'server_seq',
      limit: limit,
    );
    return rows.map(fromRow).toList();
  }

  /// Все карточки, включая tombstone.
  Future<List<KanbanCard>> all() async {
    final rows = await _db.query(table, orderBy: 'id');
    return rows.map(fromRow).toList();
  }

  /// Идентификаторы всех карточек, включая tombstone.
  Future<Set<String>> allIds() async {
    final rows = await _db.query(table, columns: const ['id']);
    return {for (final row in rows) row['id']! as String};
  }

  /// Физически удаляет карточки (полный reset клиента после 410).
  Future<void> deleteByIds(Iterable<String> ids) async {
    final batch = _db.batch();
    for (final id in ids) {
      batch.delete(table, where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  /// Физически удаляет tombstone, помеченные удалёнными раньше
  /// [beforeMillis] (хаб, чистка через 90 дней). Возвращает наибольший
  /// `server_seq` среди удалённых строк или 0, если удалять нечего.
  Future<int> purgeTombstones(int beforeMillis) async {
    // HLC-строки сравнимы лексикографически: первые 15 цифр — время.
    final bound = beforeMillis.clamp(0, Hlc.maxMillis).toString().padLeft(15, '0');
    const where = 'deleted = 1 AND hlc_deleted < ?';
    final rows = await _db.rawQuery(
      'SELECT MAX(server_seq) AS seq FROM $table WHERE $where',
      [bound],
    );
    final seq = rows.first['seq'] as int?;
    if (seq == null) return 0;
    await _db.delete(table, where: where, whereArgs: [bound]);
    return seq;
  }

  /// Вставляет или целиком заменяет карточку.
  Future<void> upsert(KanbanCard card) => _db.insert(
        table,
        toRow(card),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  /// Число строк в таблице (включая tombstone).
  Future<int> count() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS n FROM $table');
    return rows.first['n']! as int;
  }

  static Map<String, Object?> toRow(KanbanCard card) => {
        'id': card.id,
        'title': card.title,
        'description': card.description,
        'column': card.column.code,
        'pos': card.pos,
        'deleted': card.deleted ? 1 : 0,
        'created_at': card.createdAt,
        'hlc_title': card.hlcTitle.toString(),
        'hlc_description': card.hlcDescription.toString(),
        'hlc_column': card.hlcColumn.toString(),
        'hlc_pos': card.hlcPos.toString(),
        'hlc_deleted': card.hlcDeleted.toString(),
        'server_seq': card.serverSeq,
      };

  static KanbanCard fromRow(Map<String, Object?> row) => KanbanCard(
        id: row['id']! as String,
        title: row['title']! as String,
        description: row['description']! as String,
        column: BoardColumn.fromCode(row['column']! as int),
        pos: row['pos']! as String,
        deleted: row['deleted'] == 1,
        createdAt: row['created_at']! as int,
        hlcTitle: Hlc.parse(row['hlc_title']! as String),
        hlcDescription: Hlc.parse(row['hlc_description']! as String),
        hlcColumn: Hlc.parse(row['hlc_column']! as String),
        hlcPos: Hlc.parse(row['hlc_pos']! as String),
        hlcDeleted: Hlc.parse(row['hlc_deleted']! as String),
        serverSeq: row['server_seq']! as int,
      );
}

/// Доступ к таблице `devices` (хаб): привязанные телефоны.
library;

import 'package:sqflite_common/sqlite_api.dart';

/// Привязанное устройство. На хабе хранится только хэш токена.
final class PairedDevice {
  const PairedDevice({
    required this.deviceId,
    required this.name,
    required this.platform,
    required this.tokenHash,
    required this.pairedAt,
    this.lastSyncAt,
    this.revoked = false,
  });

  final String deviceId;
  final String name;
  final String platform;
  final String tokenHash;

  /// Время привязки, мс эпохи Unix.
  final int pairedAt;

  /// Время последней успешной синхронизации или `null`.
  final int? lastSyncAt;

  /// Отвязано: запросы с его токеном получают 401.
  final bool revoked;
}

class DeviceDao {
  const DeviceDao(this._db);

  final DatabaseExecutor _db;

  static const String table = 'devices';

  /// Все устройства, новые сверху.
  Future<List<PairedDevice>> all() async {
    final rows = await _db.query(table, orderBy: 'paired_at DESC');
    return rows.map(_fromRow).toList();
  }

  Future<PairedDevice?> getById(String deviceId) async {
    final rows = await _db.query(
      table,
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Привязанные (не отозванные) устройства, новые сверху.
  Future<List<PairedDevice>> active() async {
    final rows = await _db.query(
      table,
      where: 'revoked = 0',
      orderBy: 'paired_at DESC',
    );
    return rows.map(_fromRow).toList();
  }

  /// Устройство по хэшу токена (включая отозванные) или `null`.
  Future<PairedDevice?> getByTokenHash(String tokenHash) async {
    final rows = await _db.query(
      table,
      where: 'token_hash = ?',
      whereArgs: [tokenHash],
      limit: 1,
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Добавляет устройство или заменяет запись при повторной привязке.
  Future<void> upsert(PairedDevice device) => _db.insert(
        table,
        {
          'device_id': device.deviceId,
          'name': device.name,
          'platform': device.platform,
          'token_hash': device.tokenHash,
          'paired_at': device.pairedAt,
          'last_sync_at': device.lastSyncAt,
          'revoked': device.revoked ? 1 : 0,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<void> touchLastSync(String deviceId, int at) => _db.update(
        table,
        {'last_sync_at': at},
        where: 'device_id = ?',
        whereArgs: [deviceId],
      );

  Future<void> revoke(String deviceId) => _db.update(
        table,
        {'revoked': 1},
        where: 'device_id = ?',
        whereArgs: [deviceId],
      );

  static PairedDevice _fromRow(Map<String, Object?> row) => PairedDevice(
        deviceId: row['device_id']! as String,
        name: row['name']! as String,
        platform: row['platform']! as String,
        tokenHash: row['token_hash']! as String,
        pairedAt: row['paired_at']! as int,
        lastSyncAt: row['last_sync_at'] as int?,
        revoked: row['revoked'] == 1,
      );
}

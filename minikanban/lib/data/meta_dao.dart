/// Доступ к таблице `meta` (ключ → значение).
library;

import 'package:sqflite_common/sqlite_api.dart';

import '../core/hlc.dart';
import '../core/ids.dart';

/// Ключи таблицы `meta`.
abstract final class MetaKeys {
  static const String deviceId = 'device_id';
  static const String serverId = 'server_id';
  static const String seqCounter = 'seq_counter';
  static const String cursor = 'cursor';
  static const String hlcLast = 'hlc_last';
  static const String lastSyncAt = 'last_sync_at';

  /// Хаб: `server_seq`, ниже которого tombstone уже вычищены. Клиент с
  /// курсором меньше этого значения получает 410.
  static const String purgeFloor = 'purge_floor';

  // --- Клиент: привязанный ПК ---
  static const String serverName = 'server_name';
  static const String serverHost = 'server_host';
  static const String serverIps = 'server_ips';
  static const String serverPort = 'server_port';
  static const String serverFingerprint = 'server_fp';

  /// Последний адрес `ip:port`, по которому синхронизация удалась.
  static const String lastGoodEndpoint = 'last_good_endpoint';

  /// Причина остановки синхронизации (`revoked`, `cert`, `incompatible`).
  static const String syncBlock = 'sync_block';

  /// Полный reset после 410 начат, но не завершён.
  static const String resetPending = 'reset_pending';
}

class MetaDao {
  const MetaDao(this._db);

  final DatabaseExecutor _db;

  static const String table = 'meta';

  Future<String?> get(String key) async {
    final rows = await _db.query(
      table,
      columns: const ['value'],
      where: 'key = ?',
      whereArgs: [key],
    );
    return rows.isEmpty ? null : rows.first['value']! as String;
  }

  Future<void> set(String key, String value) => _db.insert(
        table,
        {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<void> remove(String key) =>
      _db.delete(table, where: 'key = ?', whereArgs: [key]);

  Future<int> getInt(String key, {int orElse = 0}) async =>
      int.tryParse(await get(key) ?? '') ?? orElse;

  Future<void> setInt(String key, int value) => set(key, value.toString());

  /// Идентификатор этого устройства: создаётся при первом обращении и
  /// больше не меняется. Вызывать внутри транзакции, чтобы два
  /// одновременных первых вызова не создали разные id.
  Future<String> ensureDeviceId() async {
    final existing = await get(MetaKeys.deviceId);
    if (existing != null) return existing;
    final id = newId();
    await set(MetaKeys.deviceId, id);
    return id;
  }

  /// Последняя выданная HLC-метка (для восстановления часов после запуска).
  Future<Hlc?> hlcLast() async {
    final raw = await get(MetaKeys.hlcLast);
    return raw == null ? null : Hlc.tryParse(raw);
  }

  Future<void> setHlcLast(Hlc value) => set(MetaKeys.hlcLast, value.toString());

  /// Текущее значение счётчика `server_seq` (последний выданный номер).
  Future<int> seqCounter() => getInt(MetaKeys.seqCounter);

  /// Выдаёт следующий `server_seq` (хаб). Вызывать только в транзакции
  /// вместе с записью карточки.
  Future<int> nextServerSeq() async {
    final next = await seqCounter() + 1;
    await setInt(MetaKeys.seqCounter, next);
    return next;
  }

  /// Курсор клиента: последний полученный от хаба `server_seq`.
  Future<int> cursor() => getInt(MetaKeys.cursor);

  Future<void> setCursor(int value) => setInt(MetaKeys.cursor, value);
}

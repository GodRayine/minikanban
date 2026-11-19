/// Сведения телефона о привязанном ПК: всё, кроме токена, — в `meta`;
/// токен — в защищённом хранилище.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../../data/meta_dao.dart';
import 'sync_api.dart';

/// Хранилище токена устройства.
abstract interface class TokenStore {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> delete();
}

/// Токен в Android Keystore (EncryptedSharedPreferences).
class SecureTokenStore implements TokenStore {
  const SecureTokenStore();

  static const String _key = 'device_token';
  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String token) => _storage.write(key: _key, value: token);

  @override
  Future<void> delete() => _storage.delete(key: _key);
}

/// Токен в памяти (тесты).
class MemoryTokenStore implements TokenStore {
  String? _token;

  @override
  Future<String?> read() async => _token;

  @override
  Future<void> write(String token) async => _token = token;

  @override
  Future<void> delete() async => _token = null;
}

/// Привязанный ПК.
final class ServerLink {
  const ServerLink({
    required this.serverId,
    required this.serverName,
    required this.host,
    required this.port,
    required this.fingerprint,
    this.ips = const [],
    this.lastGood,
  });

  final String serverId;
  final String serverName;

  /// Сетевое имя ПК (для `<host>.local`); может быть пустым.
  final String host;

  /// IP-кандидаты на момент привязки.
  final List<String> ips;
  final int port;

  /// Отпечаток SPKI сертификата ПК.
  final String fingerprint;

  /// Последний адрес, по которому обмен удался.
  final Endpoint? lastGood;
}

class ClientStore {
  ClientStore(this._db, this.tokens);

  final Database _db;
  final TokenStore tokens;

  /// Привязанный ПК или `null`.
  Future<ServerLink?> link() async {
    final meta = MetaDao(_db);
    final serverId = await meta.get(MetaKeys.serverId);
    final fingerprint = await meta.get(MetaKeys.serverFingerprint);
    final port = await meta.getInt(MetaKeys.serverPort);
    if (serverId == null || fingerprint == null || port <= 0) return null;
    var ips = const <String>[];
    try {
      final decoded = jsonDecode(await meta.get(MetaKeys.serverIps) ?? '[]');
      if (decoded is List<Object?>) ips = decoded.whereType<String>().toList();
    } on FormatException {
      // Повреждённое значение — просто нет кандидатов.
    }
    final lastGood = await meta.get(MetaKeys.lastGoodEndpoint);
    return ServerLink(
      serverId: serverId,
      serverName: await meta.get(MetaKeys.serverName) ?? 'Компьютер',
      host: await meta.get(MetaKeys.serverHost) ?? '',
      ips: ips,
      port: port,
      fingerprint: fingerprint,
      lastGood: lastGood == null ? null : Endpoint.tryParse(lastGood),
    );
  }

  /// Сохраняет привязку и токен, снимает блокировку синхронизации.
  Future<void> saveLink(ServerLink link, {required String token}) async {
    await tokens.write(token);
    await _db.transaction((txn) async {
      final meta = MetaDao(txn);
      await meta.set(MetaKeys.serverId, link.serverId);
      await meta.set(MetaKeys.serverName, link.serverName);
      await meta.set(MetaKeys.serverHost, link.host);
      await meta.set(MetaKeys.serverIps, jsonEncode(link.ips));
      await meta.setInt(MetaKeys.serverPort, link.port);
      await meta.set(MetaKeys.serverFingerprint, link.fingerprint);
      final lastGood = link.lastGood;
      if (lastGood == null) {
        await meta.remove(MetaKeys.lastGoodEndpoint);
      } else {
        await meta.set(MetaKeys.lastGoodEndpoint, lastGood.toString());
      }
      await meta.remove(MetaKeys.syncBlock);
    });
  }

  /// Забывает токен и адреса ПК. `server_id` и курсор остаются: при
  /// повторной привязке к тому же ПК полная пересылка не понадобится.
  Future<void> clearLink() async {
    await tokens.delete();
    await _db.transaction((txn) async {
      final meta = MetaDao(txn);
      for (final key in const [
        MetaKeys.serverFingerprint,
        MetaKeys.serverPort,
        MetaKeys.serverIps,
        MetaKeys.serverHost,
        MetaKeys.serverName,
        MetaKeys.lastGoodEndpoint,
        MetaKeys.syncBlock,
      ]) {
        await meta.remove(key);
      }
    });
  }

  /// `server_id` ПК, с которым телефон синхронизировался последним
  /// (сохраняется и после отвязки).
  Future<String?> knownServerId() => MetaDao(_db).get(MetaKeys.serverId);

  Future<String?> token() => tokens.read();

  Future<DateTime?> lastSyncAt() async {
    final at = await MetaDao(_db).getInt(MetaKeys.lastSyncAt);
    return at <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(at);
  }

  /// Отмечает удачный обмен: время и адрес, по которому он прошёл.
  Future<void> markSuccess(Endpoint endpoint, DateTime at) =>
      _db.transaction((txn) async {
        final meta = MetaDao(txn);
        await meta.setInt(MetaKeys.lastSyncAt, at.millisecondsSinceEpoch);
        await meta.set(MetaKeys.lastGoodEndpoint, endpoint.toString());
      });

  /// Забывает последний удачный адрес: следующий обмен начнёт поиск ПК
  /// заново (DNS-SD, имя, адреса из QR).
  Future<void> forgetLastGood() =>
      MetaDao(_db).remove(MetaKeys.lastGoodEndpoint);

  /// Причина остановки синхронизации (сейчас только `revoked`).
  Future<String?> syncBlock() => MetaDao(_db).get(MetaKeys.syncBlock);

  Future<void> setSyncBlock(String reason) =>
      MetaDao(_db).set(MetaKeys.syncBlock, reason);

  Future<bool> resetPending() async =>
      await MetaDao(_db).get(MetaKeys.resetPending) != null;

  Future<void> setResetPending() =>
      MetaDao(_db).set(MetaKeys.resetPending, '1');
}

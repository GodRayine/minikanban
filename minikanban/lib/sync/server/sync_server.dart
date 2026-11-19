/// HTTPS-сервер синхронизации на ПК (протокол v1, PLAN.md §3).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../../data/board_repository_impl.dart';
import '../../data/card_dao.dart';
import '../../data/device_dao.dart';
import '../../data/meta_dao.dart';
import '../../data/outbox_dao.dart';
import '../protocol/dto.dart';
import '../protocol/merge.dart';
import '../protocol/qr_payload.dart';
import 'cert_service.dart';
import 'pairing_service.dart';

/// Через сколько tombstone удаляется с ПК физически.
const Duration tombstoneRetention = Duration(days: 90);

/// Сколько ПК помнит применённые `change_id`.
const Duration appliedChangesRetention = Duration(days: 30);

/// Наибольший размер тела запроса.
const int maxRequestBytes = 16 * 1024 * 1024;

class _BadRequest implements Exception {
  const _BadRequest(this.message, {this.status = HttpStatus.badRequest});

  final String message;
  final int status;
}

/// Сервер: `GET /v1/hello`, `POST /v1/pair`, `POST /v1/sync`.
///
/// Входящие изменения применяются через [BoardRepositoryImpl.applyRemote],
/// поэтому доска на ПК обновляется сама (поток репозитория).
class SyncServer {
  SyncServer({
    required Database db,
    required BoardRepositoryImpl repository,
    required this.identity,
    required this.serverName,
    PairingService? pairing,
    DateTime Function()? now,
  })  : _db = db,
        _repository = repository,
        _now = now ?? DateTime.now,
        pairing = pairing ?? PairingService(db, now: now);

  static const int defaultPort = PairingQrPayload.defaultPort;

  final Database _db;
  final BoardRepositoryImpl _repository;
  final DateTime Function() _now;

  /// Сертификат и отпечаток этого ПК.
  final ServerIdentity identity;

  /// Отображаемое имя ПК.
  final String serverName;

  final PairingService pairing;

  HttpServer? _server;
  Timer? _maintenanceTimer;
  final StreamController<void> _deviceEvents =
      StreamController<void>.broadcast();

  /// Идентификатор сервера (`sid`) — он же id этого устройства.
  String get serverId => _repository.deviceId;

  bool get isRunning => _server != null;

  /// Порт, на котором слушает сервер (0, пока не запущен).
  int get port => _server?.port ?? 0;

  /// События «список устройств или время их синхронизации изменились».
  Stream<void> get deviceEvents => _deviceEvents.stream;

  /// Запускает сервер на [port]; если порт занят и разрешён
  /// [fallbackToAnyPort] — на любом свободном.
  Future<void> start({
    int port = defaultPort,
    Object? address,
    bool fallbackToAnyPort = true,
  }) async {
    if (_server != null) return;
    final bindAddress = address ?? InternetAddress.anyIPv4;
    final context = identity.securityContext();
    HttpServer server;
    try {
      server = await HttpServer.bindSecure(bindAddress, port, context);
    } on SocketException {
      if (!fallbackToAnyPort || port == 0) rethrow;
      server = await HttpServer.bindSecure(bindAddress, 0, context);
    }
    server.idleTimeout = const Duration(seconds: 30);
    _server = server;
    shelf_io.serveRequests(server, handler);

    unawaited(_safeMaintenance());
    _maintenanceTimer = Timer.periodic(
      const Duration(hours: 12),
      (_) => unawaited(_safeMaintenance()),
    );
  }

  Future<void> stop() async {
    _maintenanceTimer?.cancel();
    _maintenanceTimer = null;
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  /// Останавливает сервер и закрывает поток событий.
  Future<void> dispose() async {
    await stop();
    await _deviceEvents.close();
  }

  // --- Устройства -----------------------------------------------------------

  Future<List<PairedDevice>> devices() => pairing.devices();

  /// Отвязывает устройство.
  Future<void> revoke(String deviceId) async {
    await pairing.revoke(deviceId);
    _emitDeviceEvent();
  }

  void _emitDeviceEvent() {
    if (!_deviceEvents.isClosed) _deviceEvents.add(null);
  }

  // --- Обслуживание ---------------------------------------------------------

  Future<void> _safeMaintenance() async {
    try {
      await runMaintenance();
    } on Object catch (error) {
      debugPrint('SyncServer: обслуживание не удалось: $error');
    }
  }

  /// Удаляет старые tombstone и записи о применённых изменениях.
  /// Возвращает «пол» `server_seq`: клиентам с курсором ниже него
  /// отвечают 410 (0 — ничего ещё не вычищалось).
  Future<int> runMaintenance() async {
    final now = _now().millisecondsSinceEpoch;
    return _db.transaction((txn) async {
      final meta = MetaDao(txn);
      await AppliedChangesDao(txn)
          .purgeOlderThan(now - appliedChangesRetention.inMilliseconds);
      final purged = await CardDao(txn)
          .purgeTombstones(now - tombstoneRetention.inMilliseconds);
      final floor = await meta.getInt(MetaKeys.purgeFloor);
      if (purged > floor) {
        await meta.setInt(MetaKeys.purgeFloor, purged);
        return purged;
      }
      return floor;
    });
  }

  // --- HTTP -----------------------------------------------------------------

  /// Обработчик запросов (в тестах можно вызывать без сокета).
  late final Handler handler = _buildHandler();

  Handler _buildHandler() {
    final router = Router()
      ..get('/v1/hello', _hello)
      ..post('/v1/pair', _pair)
      ..post('/v1/sync', _sync);
    return (Request request) async {
      try {
        return await router.call(request);
      } on _BadRequest catch (e) {
        return _json(e.status, {'error': 'bad_request', 'message': e.message});
      } on Object catch (error, stack) {
        debugPrint('SyncServer: ошибка обработки запроса: $error\n$stack');
        return _json(HttpStatus.internalServerError, {'error': 'internal'});
      }
    };
  }

  static Response _json(int status, Map<String, Object?> body) => Response(
        status,
        body: jsonEncode(body),
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );

  static Future<Object?> _readJson(Request request) async {
    final declared = request.contentLength;
    if (declared != null && declared > maxRequestBytes) {
      throw const _BadRequest(
        'Слишком большой запрос',
        status: HttpStatus.requestEntityTooLarge,
      );
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in request.read()) {
      bytes.add(chunk);
      if (bytes.length > maxRequestBytes) {
        throw const _BadRequest(
          'Слишком большой запрос',
          status: HttpStatus.requestEntityTooLarge,
        );
      }
    }
    try {
      return jsonDecode(utf8.decode(bytes.takeBytes()));
    } on FormatException {
      throw const _BadRequest('Тело запроса — не JSON');
    }
  }

  static Map<String, Object?> _object(Object? json) {
    if (json is Map<String, Object?>) return json;
    throw const _BadRequest('Ожидался JSON-объект');
  }

  Response _hello(Request request) => _json(
        HttpStatus.ok,
        HelloResponse(
          serverId: serverId,
          serverName: serverName,
          time: _now().millisecondsSinceEpoch,
        ).toJson(),
      );

  Future<Response> _pair(Request request) async {
    final body = _object(await _readJson(request));
    final proof = body['code_proof'];
    final PairRequest pairRequest;
    try {
      // При привязке по доказательству сам код не передаётся.
      pairRequest = PairRequest.fromJson(
        proof is String ? {...body, 'code': '-'} : body,
      );
    } on ProtocolException catch (e) {
      throw _BadRequest(e.message);
    }
    if (proof != null && (proof is! String || proof.length > 128)) {
      throw const _BadRequest('Поле "code_proof": ожидалась строка');
    }

    final result = await pairing.pair(
      code: proof == null ? pairRequest.code : null,
      proof: proof as String?,
      fingerprint: proof == null ? null : identity.fingerprint,
      deviceId: pairRequest.deviceId,
      deviceName: pairRequest.deviceName,
      platform: pairRequest.platform,
    );
    final failure = result.failure;
    if (failure != null) {
      return _json(
        failure == PairingFailure.rateLimited
            ? HttpStatus.tooManyRequests
            : HttpStatus.forbidden,
        {'error': 'pairing_rejected', 'reason': failure.wire},
      );
    }
    _emitDeviceEvent();
    return _json(HttpStatus.ok, {
      ...PairResponse(
        deviceToken: result.deviceToken!,
        serverId: serverId,
        serverName: serverName,
      ).toJson(),
      if (result.serverProof != null) 'server_proof': result.serverProof,
    });
  }

  static String? _bearer(Request request) {
    final header = request.headers[HttpHeaders.authorizationHeader];
    if (header == null) return null;
    final match = RegExp(r'^Bearer\s+(\S+)$', caseSensitive: false)
        .firstMatch(header.trim());
    return match?.group(1);
  }

  Future<Response> _sync(Request request) async {
    final (status, device) = await pairing.authenticate(_bearer(request));
    if (status != TokenStatus.ok || device == null) {
      return _json(HttpStatus.unauthorized, {
        'error': 'unauthorized',
        'reason': status == TokenStatus.revoked ? 'revoked' : 'unknown',
      });
    }

    final body = _object(await _readJson(request));
    final cursor = body['cursor'];
    if (cursor is! int || cursor < 0) {
      throw const _BadRequest('Поле "cursor": ожидалось целое число >= 0');
    }
    final rawLimit = body['limit'] ?? maxSyncLimit;
    if (rawLimit is! int || rawLimit < 1 || rawLimit > maxSyncLimit) {
      throw const _BadRequest('Поле "limit" вне диапазона 1..$maxSyncLimit');
    }
    final rawChanges = body['changes'] ?? const <Object?>[];
    if (rawChanges is! List<Object?>) {
      throw const _BadRequest('Поле "changes": ожидался массив');
    }
    if (rawChanges.length > maxSyncLimit) {
      throw const _BadRequest('Слишком много изменений (больше $maxSyncLimit)');
    }

    // Курсор из «другой истории»: tombstone до него уже вычищены либо он
    // больше всего, что этот ПК когда-либо выдавал. Клиент делает reset.
    final meta = MetaDao(_db);
    final floor = await meta.getInt(MetaKeys.purgeFloor);
    final top = await meta.seqCounter();
    if ((cursor > 0 && cursor < floor) || cursor > top) {
      return _json(HttpStatus.gone, {'error': 'gone', 'reason': 'cursor'});
    }

    // Некорректное изменение пропускаем: оно не попадёт в `applied`, а
    // остальные будут приняты.
    final changes = <CardChange>[];
    for (final raw in rawChanges) {
      try {
        changes.add(CardChange.fromJson(raw));
      } on ProtocolException {
        continue;
      }
    }
    final applied = await _apply(changes);

    final cards = await CardDao(_db).changedSince(cursor, limit: rawLimit + 1);
    final hasMore = cards.length > rawLimit;
    final page = hasMore ? cards.sublist(0, rawLimit) : cards;
    final outgoing = <CardChange>[];
    for (final card in page) {
      final change = diffToChange(null, card, changeId: 's${card.serverSeq}');
      if (change != null) outgoing.add(change);
    }

    await DeviceDao(_db)
        .touchLastSync(device.deviceId, _now().millisecondsSinceEpoch);
    _emitDeviceEvent();

    return _json(
      HttpStatus.ok,
      SyncResponse(
        applied: applied,
        changes: outgoing,
        cursor: page.isEmpty ? cursor : page.last.serverSeq,
        hasMore: hasMore,
      ).toJson(),
    );
  }

  /// Применяет изменения одной транзакцией; если пакет отвергнут целиком,
  /// — по одному, пропуская негодные.
  Future<List<String>> _apply(List<CardChange> changes) async {
    if (changes.isEmpty) return const [];
    try {
      return (await _repository.applyRemote(changes)).accepted;
    } on ProtocolException {
      final applied = <String>[];
      for (final change in changes) {
        try {
          applied.addAll((await _repository.applyRemote([change])).accepted);
        } on ProtocolException {
          continue;
        }
      }
      return applied;
    }
  }
}

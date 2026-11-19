/// DTO протокола синхронизации v1 с ручной (де)сериализацией JSON.
///
/// Все `fromJson` принимают результат `jsonDecode` и бросают
/// [ProtocolException] при любом нарушении формата.
library;

import '../../core/fractional_index.dart';
import '../../core/hlc.dart';
import '../../domain/card.dart';

/// Версия протокола; несовпадение с `proto` из `/v1/hello` — «Несовместимая
/// версия».
const int protocolVersion = 1;

/// Максимум изменений в одном запросе/ответе `/v1/sync`.
const int maxSyncLimit = 500;

/// Единственный тип сущности в v1.
const String cardEntity = 'card';

/// Ключ неизменяемого поля «время создания» в `fields` (без HLC-метки).
const String createdAtKey = 'created_at';

/// Сообщение протокола не соответствует формату v1.
class ProtocolException implements Exception {
  const ProtocolException(this.message);

  final String message;

  @override
  String toString() => 'ProtocolException: $message';
}

// --- Вспомогательные проверки ----------------------------------------------

Map<String, Object?> _asMap(Object? json, String what) {
  if (json is Map<String, Object?>) return json;
  if (json is Map<Object?, Object?> && json.keys.every((k) => k is String)) {
    return json.cast<String, Object?>();
  }
  throw ProtocolException('$what: ожидался JSON-объект');
}

List<Object?> _reqList(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is List<Object?>) return value;
  throw ProtocolException('Поле "$key": ожидался массив');
}

String _reqString(
  Map<String, Object?> map,
  String key, {
  int maxLength = 512,
  bool allowEmpty = false,
}) {
  final value = map[key];
  if (value is! String) {
    throw ProtocolException('Поле "$key": ожидалась строка');
  }
  if (!allowEmpty && value.isEmpty) {
    throw ProtocolException('Поле "$key" не должно быть пустым');
  }
  if (value.length > maxLength) {
    throw ProtocolException('Поле "$key" длиннее $maxLength символов');
  }
  return value;
}

int _reqInt(Map<String, Object?> map, String key, {int min = 0, int? max}) {
  final value = map[key];
  if (value is! int) {
    throw ProtocolException('Поле "$key": ожидалось целое число');
  }
  if (value < min || (max != null && value > max)) {
    throw ProtocolException('Поле "$key" вне допустимого диапазона');
  }
  return value;
}

bool _reqBool(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is bool) return value;
  throw ProtocolException('Поле "$key": ожидалось true/false');
}

bool _mapEquals<V>(Map<String, V> a, Map<String, V> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    if (!b.containsKey(e.key) || b[e.key] != e.value) return false;
  }
  return true;
}

int _mapHash(Map<String, Object?> map) => Object.hashAllUnordered(
      map.entries.map((e) => Object.hash(e.key, e.value)),
    );

// --- CardChange ------------------------------------------------------------

/// Одно изменение карточки: набор полей и HLC-метка на каждое из них.
///
/// [fields] — wire-значения: `title`/`description`/`pos` — строки,
/// `column` — int 0..2, `deleted` — bool, плюс необязательный
/// [createdAtKey] (int, мс) без метки. [hlc] содержит метку ровно для
/// каждого поля из [CardField], присутствующего в [fields].
final class CardChange {
  const CardChange({
    required this.changeId,
    required this.id,
    required this.fields,
    required this.hlc,
    this.entity = cardEntity,
  });

  factory CardChange.fromJson(Object? json) {
    final map = _asMap(json, 'change');
    final entity = _reqString(map, 'entity');
    if (entity != cardEntity) {
      throw ProtocolException('Неизвестная сущность "$entity"');
    }
    final rawFields = _asMap(map['fields'], 'fields');
    final rawHlc = _asMap(map['hlc'], 'hlc');

    final fields = <String, Object?>{};
    final hlc = <String, Hlc>{};
    for (final MapEntry(:key, :value) in rawFields.entries) {
      if (key == createdAtKey) {
        if (value is! int || value < 0) {
          throw const ProtocolException(
            'Поле "$createdAtKey": ожидалось целое число >= 0',
          );
        }
        fields[key] = value;
        continue;
      }
      final field = CardField.tryParse(key);
      if (field == null) {
        throw ProtocolException('Неизвестное поле карточки "$key"');
      }
      fields[key] = validateFieldValue(field, value);
      final stamp = rawHlc[key];
      final parsed = stamp is String ? Hlc.tryParse(stamp) : null;
      if (parsed == null) {
        throw ProtocolException('Нет корректной HLC-метки для поля "$key"');
      }
      hlc[key] = parsed;
    }
    if (hlc.isEmpty) {
      throw const ProtocolException('Изменение не содержит полей карточки');
    }
    for (final key in rawHlc.keys) {
      if (!hlc.containsKey(key)) {
        throw ProtocolException('HLC-метка для отсутствующего поля "$key"');
      }
    }
    return CardChange(
      changeId: _reqString(map, 'change_id', maxLength: 64),
      entity: entity,
      id: _reqString(map, 'id', maxLength: 64),
      fields: Map.unmodifiable(fields),
      hlc: Map.unmodifiable(hlc),
    );
  }

  /// Проверяет wire-значение поля карточки и возвращает его типизированным
  /// (`String`, `int` или `bool`). Значение не преобразуется: все узлы
  /// должны хранить одно и то же, иначе состояния разойдутся.
  static Object validateFieldValue(CardField field, Object? value) {
    switch (field) {
      case CardField.title:
        if (value is String) {
          final error = KanbanCard.titleError(value);
          if (error == null) return value;
          throw ProtocolException('Поле "title": $error');
        }
      case CardField.description:
        if (value is String) {
          final error = KanbanCard.descriptionError(value);
          if (error == null) return value;
          throw ProtocolException('Поле "description": $error');
        }
      case CardField.column:
        if (value is int && BoardColumn.tryFromCode(value) != null) {
          return value;
        }
      case CardField.pos:
        if (value is String && value.length <= 256 && isValidKey(value)) {
          return value;
        }
      case CardField.deleted:
        if (value is bool) return value;
    }
    throw ProtocolException('Поле "${field.wire}": некорректное значение');
  }

  /// Идентификатор изменения (uuid) — ключ идемпотентности.
  final String changeId;
  final String entity;

  /// Идентификатор карточки.
  final String id;
  final Map<String, Object?> fields;
  final Map<String, Hlc> hlc;

  /// Время создания из [fields] или `null`, если не передано.
  int? get createdAt => switch (fields[createdAtKey]) {
        final int v => v,
        _ => null,
      };

  Map<String, Object?> toJson() => {
        'change_id': changeId,
        'entity': entity,
        'id': id,
        'fields': {...fields},
        'hlc': {for (final e in hlc.entries) e.key: e.value.toString()},
      };

  @override
  bool operator ==(Object other) =>
      other is CardChange &&
      other.changeId == changeId &&
      other.entity == entity &&
      other.id == id &&
      _mapEquals(other.fields, fields) &&
      _mapEquals(other.hlc, hlc);

  @override
  int get hashCode =>
      Object.hash(changeId, entity, id, _mapHash(fields), _mapHash(hlc));

  @override
  String toString() => 'CardChange($changeId, card=$id, fields=$fields)';
}

List<CardChange> _changes(Map<String, Object?> map) {
  final list = _reqList(map, 'changes');
  if (list.length > maxSyncLimit) {
    throw const ProtocolException(
      'Слишком много изменений (больше $maxSyncLimit)',
    );
  }
  return List.unmodifiable(list.map(CardChange.fromJson));
}

// --- /v1/sync --------------------------------------------------------------

/// Запрос `POST /v1/sync`: исходящие изменения клиента и его курсор.
final class SyncRequest {
  const SyncRequest({
    required this.cursor,
    this.changes = const [],
    this.limit = maxSyncLimit,
  });

  factory SyncRequest.fromJson(Object? json) {
    final map = _asMap(json, 'sync request');
    return SyncRequest(
      cursor: _reqInt(map, 'cursor'),
      changes: _changes(map),
      limit: map.containsKey('limit')
          ? _reqInt(map, 'limit', min: 1, max: maxSyncLimit)
          : maxSyncLimit,
    );
  }

  /// Последний `server_seq`, полученный клиентом (0 — с начала).
  final int cursor;
  final List<CardChange> changes;

  /// Сколько изменений сервер может вернуть за раз (1..[maxSyncLimit]).
  final int limit;

  Map<String, Object?> toJson() => {
        'cursor': cursor,
        'changes': [for (final c in changes) c.toJson()],
        'limit': limit,
      };
}

/// Ответ `POST /v1/sync`.
final class SyncResponse {
  const SyncResponse({
    required this.cursor,
    this.applied = const [],
    this.changes = const [],
    this.hasMore = false,
  });

  factory SyncResponse.fromJson(Object? json) {
    final map = _asMap(json, 'sync response');
    final applied = _reqList(map, 'applied');
    if (applied.any((e) => e is! String || e.isEmpty)) {
      throw const ProtocolException('Поле "applied": ожидались строки');
    }
    return SyncResponse(
      applied: List.unmodifiable(applied.cast<String>()),
      changes: _changes(map),
      cursor: _reqInt(map, 'cursor'),
      hasMore: _reqBool(map, 'has_more'),
    );
  }

  /// `change_id` принятых изменений (их можно убрать из outbox).
  final List<String> applied;

  /// Изменения с сервера после курсора запроса.
  final List<CardChange> changes;

  /// Новый курсор клиента.
  final int cursor;

  /// Есть ли ещё изменения — нужно повторить запрос с новым курсором.
  final bool hasMore;

  Map<String, Object?> toJson() => {
        'applied': [...applied],
        'changes': [for (final c in changes) c.toJson()],
        'cursor': cursor,
        'has_more': hasMore,
      };
}

// --- /v1/pair --------------------------------------------------------------

/// Запрос `POST /v1/pair` — телефон предъявляет одноразовый код из QR.
final class PairRequest {
  const PairRequest({
    required this.code,
    required this.deviceId,
    required this.deviceName,
    required this.platform,
  });

  factory PairRequest.fromJson(Object? json) {
    final map = _asMap(json, 'pair request');
    return PairRequest(
      code: _reqString(map, 'code', maxLength: 64),
      deviceId: _reqString(map, 'device_id', maxLength: 64),
      deviceName: _reqString(map, 'device_name', maxLength: 128),
      platform: _reqString(map, 'platform', maxLength: 32),
    );
  }

  final String code;
  final String deviceId;
  final String deviceName;

  /// Например, `android` или `windows`.
  final String platform;

  Map<String, Object?> toJson() => {
        'code': code,
        'device_id': deviceId,
        'device_name': deviceName,
        'platform': platform,
      };
}

/// Ответ `POST /v1/pair` — токен устройства и сведения о сервере.
final class PairResponse {
  const PairResponse({
    required this.deviceToken,
    required this.serverId,
    required this.serverName,
  });

  factory PairResponse.fromJson(Object? json) {
    final map = _asMap(json, 'pair response');
    return PairResponse(
      deviceToken: _reqString(map, 'device_token'),
      serverId: _reqString(map, 'server_id', maxLength: 64),
      serverName: _reqString(map, 'server_name', maxLength: 128),
    );
  }

  /// Bearer-токен; хранить только в secure storage.
  final String deviceToken;
  final String serverId;
  final String serverName;

  Map<String, Object?> toJson() => {
        'device_token': deviceToken,
        'server_id': serverId,
        'server_name': serverName,
      };
}

// --- /v1/hello -------------------------------------------------------------

/// Ответ `GET /v1/hello` — проверка, что это «наш» сервер нужной версии.
final class HelloResponse {
  const HelloResponse({
    required this.serverId,
    required this.serverName,
    required this.time,
    this.proto = protocolVersion,
  });

  factory HelloResponse.fromJson(Object? json) {
    final map = _asMap(json, 'hello');
    return HelloResponse(
      serverId: _reqString(map, 'server_id', maxLength: 64),
      serverName: _reqString(map, 'server_name', maxLength: 128),
      proto: _reqInt(map, 'proto', min: 1),
      time: _reqInt(map, 'time'),
    );
  }

  final String serverId;
  final String serverName;

  /// Версия протокола сервера; см. [isCompatible].
  final int proto;

  /// Время сервера, мс эпохи Unix.
  final int time;

  /// Совпадает ли версия протокола сервера с нашей.
  bool get isCompatible => proto == protocolVersion;

  Map<String, Object?> toJson() => {
        'server_id': serverId,
        'server_name': serverName,
        'proto': proto,
        'time': time,
      };
}

/// Чистые функции LWW-слияния карточек по полям.
library;

import '../../core/fractional_index.dart';
import '../../core/hlc.dart';
import '../../domain/card.dart';
import 'dto.dart';

/// Результат [mergeCard].
final class MergeResult {
  const MergeResult({
    required this.card,
    required this.changed,
    this.appliedFields = const {},
  });

  /// Карточка после слияния (тот же объект, что и local, если не изменилась).
  final KanbanCard card;

  /// Отличается ли [card] от локальной (или создана заново).
  final bool changed;

  /// Поля, значения которых взяты из входящего изменения.
  final Set<CardField> appliedFields;
}

/// Сливает входящее изменение [incoming] с локальной карточкой [local].
///
/// Правила:
/// * поле применяется, только если его HLC строго больше локальной метки
///   этого поля. Сравнение [Hlc] полное (время, счётчик, nodeId), так что
///   при равном времени исход детерминированно решает nodeId; полностью
///   равные метки означают то же самое изменение и пропускаются;
/// * если [local] == `null`, карточка создаётся из изменения; не пришедшие
///   поля получают значения по умолчанию с меткой [Hlc.zero], поэтому любая
///   настоящая правка их позже перекроет;
/// * `created_at` неизменяем и сходится как минимум из известных значений
///   (0 = «неизвестно»);
/// * `serverSeq` функция не трогает — его назначает хаб при записи.
///
/// Функция идемпотентна, коммутативна и ассоциативна по набору изменений:
/// итог не зависит от порядка и повторов доставки.
///
/// Бросает [ProtocolException], если значение поля некорректно, и
/// [ArgumentError], если id карточки и изменения не совпадают.
MergeResult mergeCard(KanbanCard? local, CardChange incoming) {
  if (local != null && local.id != incoming.id) {
    throw ArgumentError('mergeCard: id карточки и изменения не совпадают');
  }

  var card = local ??
      KanbanCard(id: incoming.id, title: '', pos: firstKey, createdAt: 0);
  final applied = <CardField>{};

  for (final field in CardField.values) {
    final key = field.wire;
    if (!incoming.fields.containsKey(key)) continue;
    final stamp = incoming.hlc[key];
    if (stamp == null) {
      throw ProtocolException('Нет HLC-метки для поля "$key"');
    }
    if (stamp <= card.hlcOf(field)) continue;
    card = _applyField(card, field, incoming.fields[key], stamp);
    applied.add(field);
  }

  final createdAt = _mergeCreatedAt(card.createdAt, incoming.createdAt);
  final createdAtChanged = createdAt != card.createdAt;
  if (createdAtChanged) card = card.copyWith(createdAt: createdAt);

  final changed = local == null || applied.isNotEmpty || createdAtChanged;
  return MergeResult(
    card: card,
    changed: changed,
    appliedFields: applied,
  );
}

int _mergeCreatedAt(int local, int? incoming) {
  if (incoming == null || incoming <= 0) return local;
  if (local <= 0) return incoming;
  return incoming < local ? incoming : local;
}

KanbanCard _applyField(
  KanbanCard card,
  CardField field,
  Object? raw,
  Hlc stamp,
) {
  final value = CardChange.validateFieldValue(field, raw);
  return switch (field) {
    CardField.title => card.copyWith(title: value as String, hlcTitle: stamp),
    CardField.description =>
      card.copyWith(description: value as String, hlcDescription: stamp),
    CardField.column => card.copyWith(
        column: BoardColumn.fromCode(value as int),
        hlcColumn: stamp,
      ),
    CardField.pos => card.copyWith(pos: value as String, hlcPos: stamp),
    CardField.deleted =>
      card.copyWith(deleted: value as bool, hlcDeleted: stamp),
  };
}

/// Wire-значение поля [field] карточки [card] (как в `CardChange.fields`).
Object wireValue(KanbanCard card, CardField field) => switch (field) {
      CardField.title => card.title,
      CardField.description => card.description,
      CardField.column => card.column.code,
      CardField.pos => card.pos,
      CardField.deleted => card.deleted,
    };

/// Строит исходящее изменение из локальной правки `before → after`.
///
/// В изменение попадают поля, чья HLC-метка в [after] строго больше, чем
/// в [before] (см. `KanbanCard.edit`). При `before == null` — все поля
/// с ненулевой меткой, т.е. полное состояние карточки (создание либо
/// выгрузка с хаба). `created_at` прикладывается всегда, если известен.
///
/// Возвращает `null`, если отправлять нечего.
CardChange? diffToChange(
  KanbanCard? before,
  KanbanCard after, {
  required String changeId,
}) {
  if (before != null && before.id != after.id) {
    throw ArgumentError('diffToChange: сравниваются разные карточки');
  }
  final fields = <String, Object?>{};
  final hlc = <String, Hlc>{};
  for (final field in CardField.values) {
    final stamp = after.hlcOf(field);
    if (stamp <= (before?.hlcOf(field) ?? Hlc.zero)) continue;
    fields[field.wire] = wireValue(after, field);
    hlc[field.wire] = stamp;
  }
  if (hlc.isEmpty) return null;
  if (after.createdAt > 0) fields[createdAtKey] = after.createdAt;
  return CardChange(
    changeId: changeId,
    id: after.id,
    fields: Map.unmodifiable(fields),
    hlc: Map.unmodifiable(hlc),
  );
}

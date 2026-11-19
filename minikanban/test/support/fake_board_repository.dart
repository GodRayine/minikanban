import 'dart:async';

import 'package:minikanban/core/fractional_index.dart';
import 'package:minikanban/core/hlc.dart';
import 'package:minikanban/domain/board_repository.dart';
import 'package:minikanban/domain/card.dart';

/// Хранилище доски в памяти для виджет-тестов (без SQLite и изолятов).
class FakeBoardRepository implements BoardRepository {
  final Map<String, KanbanCard> _cards = {};
  final StreamController<BoardSnapshot> _changes =
      StreamController<BoardSnapshot>.broadcast(sync: true);
  final HlcClock _clock = HlcClock(nodeId: 'test');
  int _nextId = 1;

  BoardSnapshot get snapshot => BoardSnapshot.fromCards(_cards.values);

  List<String> titles(BoardColumn column) =>
      [for (final c in snapshot.cards(column)) c.title];

  KanbanCard byTitle(String title) =>
      _cards.values.firstWhere((c) => c.title == title);

  void _emit() => _changes.add(snapshot);

  KanbanCard _require(String id) =>
      _cards[id] ?? (throw StateError('Карточка $id не найдена'));

  @override
  Stream<BoardSnapshot> watchBoard() => Stream.multi((listener) {
        listener.add(snapshot);
        final sub = _changes.stream.listen(listener.addSync);
        listener.onCancel = sub.cancel;
      });

  @override
  Future<KanbanCard> create({
    required String title,
    String description = '',
    BoardColumn column = BoardColumn.todo,
  }) async {
    final siblings = snapshot.cards(column);
    final card = KanbanCard.create(
      id: 'card-${_nextId++}',
      title: title,
      description: description,
      column: column,
      pos: keyBetween(siblings.isEmpty ? null : siblings.last.pos, null),
      createdAt: 1,
      hlc: _clock.send(),
    );
    _cards[card.id] = card;
    _emit();
    return card;
  }

  @override
  Future<KanbanCard> update(
    String id, {
    String? title,
    String? description,
  }) async {
    final card = _require(id).edit(
      hlc: _clock.send(),
      title: title,
      description: description,
    );
    _cards[id] = card;
    _emit();
    return card;
  }

  @override
  Future<KanbanCard> move(
    String id, {
    required BoardColumn column,
    String? beforeId,
    String? afterId,
  }) async {
    final card = _require(id);
    final others = [
      for (final c in snapshot.cards(column))
        if (c.id != id) c,
    ];
    var index = others.length;
    final after = others.indexWhere((c) => c.id == afterId);
    final before = others.indexWhere((c) => c.id == beforeId);
    if (after >= 0) {
      index = after + 1;
    } else if (before >= 0) {
      index = before;
    }
    final moved = card.edit(
      hlc: _clock.send(),
      column: column,
      pos: keyBetween(
        index > 0 ? others[index - 1].pos : null,
        index < others.length ? others[index].pos : null,
      ),
    );
    _cards[id] = moved;
    _emit();
    return moved;
  }

  @override
  Future<void> delete(String id) async {
    _cards[id] = _require(id).edit(hlc: _clock.send(), deleted: true);
    _emit();
  }

  @override
  Future<KanbanCard> restore(String id) async {
    final card = _require(id).edit(hlc: _clock.send(), deleted: false);
    _cards[id] = card;
    _emit();
    return card;
  }
}

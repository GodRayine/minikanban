import 'package:flutter_test/flutter_test.dart';
import 'package:minikanban/core/hlc.dart';
import 'package:minikanban/core/ids.dart';
import 'package:minikanban/domain/board_repository.dart';
import 'package:minikanban/domain/card.dart';

void main() {
  const h1 = Hlc(1000, 0, 'pc');
  const h2 = Hlc(2000, 0, 'pc');

  KanbanCard make({String id = 'c1', String pos = 'a0'}) => KanbanCard.create(
        id: id,
        title: '  Задача  ',
        pos: pos,
        createdAt: 1000,
        hlc: h1,
      );

  group('BoardColumn', () {
    test('коды и подписи', () {
      expect(BoardColumn.todo.code, 0);
      expect(BoardColumn.doing.code, 1);
      expect(BoardColumn.done.code, 2);
      expect(BoardColumn.todo.label, 'Не начато');
      expect(BoardColumn.doing.label, 'В процессе');
      expect(BoardColumn.done.label, 'Готово');
    });

    test('fromCode', () {
      for (final c in BoardColumn.values) {
        expect(BoardColumn.fromCode(c.code), c);
      }
      expect(BoardColumn.tryFromCode(3), isNull);
      expect(() => BoardColumn.fromCode(-1), throwsArgumentError);
    });
  });

  group('KanbanCard: валидация', () {
    test('create обрезает заголовок и ставит метки', () {
      final card = make();
      expect(card.title, 'Задача');
      expect(card.description, '');
      expect(card.column, BoardColumn.todo);
      expect(card.deleted, isFalse);
      expect(card.serverSeq, 0);
      for (final f in CardField.values) {
        expect(card.hlcOf(f), h1);
      }
      expect(card.maxHlc, h1);
    });

    test('заголовок 1..120 после trim', () {
      expect(KanbanCard.titleError(''), isNotNull);
      expect(KanbanCard.titleError('   '), isNotNull);
      expect(KanbanCard.titleError('a'), isNull);
      expect(KanbanCard.titleError('я' * 120), isNull);
      expect(KanbanCard.titleError('  ${'я' * 120}  '), isNull);
      expect(KanbanCard.titleError('я' * 121), isNotNull);
      expect(
        () => KanbanCard.normalizeTitle(' '),
        throwsA(isA<CardValidationException>()),
      );
    });

    test('описание до 2000', () {
      expect(KanbanCard.descriptionError(''), isNull);
      expect(KanbanCard.descriptionError('x' * 2000), isNull);
      expect(KanbanCard.descriptionError('x' * 2001), isNotNull);
      expect(
        () => make().edit(hlc: h2, description: 'x' * 2001),
        throwsA(isA<CardValidationException>()),
      );
    });
  });

  group('KanbanCard: изменение', () {
    test('edit метит только реально изменённые поля', () {
      final card = make();
      final edited = card.edit(
        hlc: h2,
        title: 'Задача', // то же значение
        column: BoardColumn.done,
      );
      expect(edited.hlcTitle, h1);
      expect(edited.hlcColumn, h2);
      expect(edited.column, BoardColumn.done);
      expect(edited.maxHlc, h2);
      expect(card.column, BoardColumn.todo, reason: 'исходная не меняется');
    });

    test('copyWith, == и hashCode', () {
      final a = make();
      final b = make();
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.copyWith(serverSeq: 5), isNot(a));
      expect(a.copyWith(hlcPos: h2), isNot(a));
      expect(a.copyWith(), a);
    });
  });

  test('BoardSnapshot раскладывает и сортирует по (pos, id)', () {
    final snapshot = BoardSnapshot.fromCards([
      make(id: 'b', pos: 'a1'),
      make(id: 'z', pos: 'a0'),
      make(id: 'a', pos: 'a0'),
      make(id: 'd', pos: 'Zz').edit(hlc: h2, deleted: true),
      make(id: 'e', pos: 'a2').edit(hlc: h2, column: BoardColumn.done),
    ]);
    expect(
      snapshot.cards(BoardColumn.todo).map((c) => c.id).toList(),
      ['a', 'z', 'b'],
    );
    expect(snapshot.cards(BoardColumn.doing), isEmpty);
    expect(snapshot.cards(BoardColumn.done).single.id, 'e');
    expect(snapshot.length, 4);
    expect(BoardSnapshot.empty.length, 0);
  });

  test('newId выдаёт уникальные uuid v4', () {
    final ids = {for (var i = 0; i < 100; i++) newId()};
    expect(ids.length, 100);
    expect(ids.every(isUuid), isTrue);
    expect(ids.every((id) => id[14] == '4'), isTrue);
    expect(isUuid('not-a-uuid'), isFalse);
  });
}

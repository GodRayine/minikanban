import 'package:flutter_test/flutter_test.dart';
import 'package:minikanban/core/hlc.dart';
import 'package:minikanban/domain/card.dart';
import 'package:minikanban/sync/protocol/dto.dart';
import 'package:minikanban/sync/protocol/merge.dart';

const cardId = 'c1';

Hlc pc(int ms, [int counter = 0]) => Hlc(ms, counter, 'pc');
Hlc phone(int ms, [int counter = 0]) => Hlc(ms, counter, 'ph');

/// Изменение, где у всех полей одна метка.
CardChange change(String changeId, Map<String, Object?> fields, Hlc hlc) =>
    CardChange(
      changeId: changeId,
      id: cardId,
      fields: fields,
      hlc: {
        for (final key in fields.keys)
          if (key != createdAtKey) key: hlc,
      },
    );

Iterable<List<T>> permutations<T>(List<T> items) sync* {
  if (items.length <= 1) {
    yield [...items];
    return;
  }
  for (var i = 0; i < items.length; i++) {
    final rest = [...items]..removeAt(i);
    for (final tail in permutations(rest)) {
      yield [items[i], ...tail];
    }
  }
}

KanbanCard? applyAll(KanbanCard? start, Iterable<CardChange> changes) {
  var card = start;
  for (final c in changes) {
    card = mergeCard(card, c).card;
  }
  return card;
}

void main() {
  final base = KanbanCard.create(
    id: cardId,
    title: 'Задача',
    description: 'Описание',
    pos: 'a0',
    createdAt: 1000,
    hlc: pc(1000),
  );

  group('одно поле с обеих сторон', () {
    test('побеждает более поздняя метка', () {
      final local = base.edit(hlc: pc(2000), title: 'С ПК');
      final r =
          mergeCard(local, change('x', {'title': 'С телефона'}, phone(3000)));
      expect(r.changed, isTrue);
      expect(r.appliedFields, {CardField.title});
      expect(r.card.title, 'С телефона');
      expect(r.card.hlcTitle, phone(3000));
    });

    test('более ранняя входящая правка игнорируется', () {
      final local = base.edit(hlc: pc(2000), title: 'С ПК');
      final r =
          mergeCard(local, change('x', {'title': 'С телефона'}, phone(1500)));
      expect(r.changed, isFalse);
      expect(r.appliedFields, isEmpty);
      expect(identical(r.card, local), isTrue);
    });

    test('при равном времени решает nodeId — одинаково на обеих сторонах', () {
      // ph > pc, значит побеждает правка телефона, кто бы ни сливал.
      final onPc = mergeCard(
        base.edit(hlc: pc(2000), title: 'С ПК'),
        change('x', {'title': 'С телефона'}, phone(2000)),
      );
      final onPhone = mergeCard(
        base.edit(hlc: phone(2000), title: 'С телефона'),
        change('y', {'title': 'С ПК'}, pc(2000)),
      );
      expect(onPc.card.title, 'С телефона');
      expect(onPc.changed, isTrue);
      expect(onPhone.card.title, 'С телефона');
      expect(onPhone.changed, isFalse);
      expect(onPc.card, onPhone.card);
    });

    test('счётчик HLC учитывается', () {
      final local = base.edit(hlc: pc(2000, 5), title: 'Поздняя');
      final r =
          mergeCard(local, change('x', {'title': 'Ранняя'}, phone(2000, 4)));
      expect(r.changed, isFalse);
      expect(r.card.title, 'Поздняя');
    });
  });

  test('разные поля — обе правки сохраняются', () {
    final local = base.edit(hlc: pc(2000), description: 'Новое описание');
    final r = mergeCard(
        local, change('x', {'title': 'Новый заголовок'}, phone(1500)));
    expect(r.changed, isTrue);
    expect(r.card.title, 'Новый заголовок');
    expect(r.card.description, 'Новое описание');
    expect(r.card.hlcTitle, phone(1500));
    expect(r.card.hlcDescription, pc(2000));
  });

  group('delete vs edit', () {
    test('правка заголовка не воскрешает удалённую карточку', () {
      final local = base.edit(hlc: pc(2000), deleted: true);
      final r = mergeCard(local, change('x', {'title': 'Правка'}, phone(3000)));
      expect(r.card.deleted, isTrue);
      expect(r.card.title, 'Правка', reason: 'правка не теряется');
    });

    test('удаление не затирает параллельную правку', () {
      final local = base.edit(hlc: pc(3000), title: 'Правка');
      final r = mergeCard(local, change('x', {'deleted': true}, phone(2000)));
      expect(r.card.deleted, isTrue);
      expect(r.card.title, 'Правка');
    });

    test('восстановление позже удаления побеждает', () {
      final local = base.edit(hlc: pc(2000), deleted: true);
      final restored =
          mergeCard(local, change('x', {'deleted': false}, phone(2500)));
      expect(restored.card.deleted, isFalse);
      final stale =
          mergeCard(restored.card, change('y', {'deleted': true}, pc(2100)));
      expect(stale.changed, isFalse);
      expect(stale.card.deleted, isFalse);
    });
  });

  test('перенос vs правка заголовка — сохраняются обе', () {
    final move = change('m', {'column': 2, 'pos': 'a5'}, phone(2000));
    final rename = change('r', {'title': 'Переименовано'}, pc(2500));

    final a = applyAll(base, [move, rename])!;
    final b = applyAll(base, [rename, move])!;
    expect(a, b);
    expect(a.column, BoardColumn.done);
    expect(a.pos, 'a5');
    expect(a.title, 'Переименовано');
    expect(a.hlcColumn, phone(2000));
    expect(a.hlcPos, phone(2000));
    expect(a.hlcTitle, pc(2500));
    expect(a.description, 'Описание');
  });

  test('повторная доставка идемпотентна', () {
    final c = change('x', {'title': 'Новое', 'column': 1}, phone(2000));
    final first = mergeCard(base, c);
    final second = mergeCard(first.card, c);
    expect(first.changed, isTrue);
    expect(second.changed, isFalse);
    expect(second.appliedFields, isEmpty);
    expect(second.card, first.card);
    expect(identical(second.card, first.card), isTrue);
  });

  group('порядок доставки не влияет на итог', () {
    final create = diffToChange(null, base, changeId: 'create')!;
    final changes = [
      create,
      change('t-ph', {'title': 'Телефон'}, phone(2000)),
      change('t-pc', {'title': 'ПК'}, pc(2000)), // tie → побеждает ph
      change('move', {'column': 1, 'pos': 'a3'}, pc(2100)),
      change('del', {'deleted': true}, phone(2200)),
    ];

    test('все перестановки с нуля сходятся', () {
      KanbanCard? expected;
      var count = 0;
      for (final order in permutations(changes)) {
        final result = applyAll(null, order)!;
        expected ??= result;
        expect(result, expected,
            reason: order.map((c) => c.changeId).join(','));
        count++;
      }
      expect(count, 120);
      expect(expected!.title, 'Телефон');
      expect(expected.description, 'Описание');
      expect(expected.column, BoardColumn.doing);
      expect(expected.pos, 'a3');
      expect(expected.deleted, isTrue);
      expect(expected.createdAt, 1000);
    });

    test('перестановки с повторами поверх существующей карточки', () {
      final edits = changes.sublist(1);
      final expected = applyAll(base, edits)!;
      for (final order in permutations(edits)) {
        expect(applyAll(base, [...order, ...order.reversed]), expected);
      }
    });
  });

  group('создание из изменения', () {
    test('полное изменение воссоздаёт карточку', () {
      final create = diffToChange(null, base, changeId: 'create')!;
      final r = mergeCard(null, create);
      expect(r.changed, isTrue);
      expect(r.appliedFields, CardField.values.toSet());
      expect(r.card, base);
    });

    test('неполное изменение — дефолты с минимальной меткой', () {
      final r = mergeCard(null, change('del', {'deleted': true}, phone(2200)));
      expect(r.changed, isTrue);
      expect(r.card.id, cardId);
      expect(r.card.deleted, isTrue);
      expect(r.card.hlcDeleted, phone(2200));
      expect(r.card.title, '');
      expect(r.card.column, BoardColumn.todo);
      expect(r.card.hlcTitle, Hlc.zero);
      expect(r.card.hlcColumn, Hlc.zero);
      expect(r.card.createdAt, 0);

      // Опоздавшее создание заполняет остальные поля, но не отменяет удаление.
      final create = diffToChange(null, base, changeId: 'create')!;
      final full = mergeCard(r.card, create).card;
      expect(full.title, 'Задача');
      expect(full.deleted, isTrue);
      expect(full.createdAt, 1000);
    });

    test('created_at сходится к минимуму известных значений', () {
      final later =
          change('x', {'title': 'A', createdAtKey: 5000}, phone(2000));
      final r = mergeCard(base, later);
      expect(r.card.createdAt, 1000);
      final earlier =
          change('y', {'title': 'B', createdAtKey: 500}, phone(900));
      final r2 = mergeCard(base, earlier);
      expect(r2.card.createdAt, 500);
      expect(r2.changed, isTrue);
      expect(r2.appliedFields, isEmpty);
    });
  });

  group('ошибки', () {
    test('несовпадение id', () {
      final other = CardChange(
        changeId: 'x',
        id: 'other',
        fields: const {'title': 'T'},
        hlc: {'title': phone(2000)},
      );
      expect(() => mergeCard(base, other), throwsArgumentError);
    });

    test('некорректное значение поля', () {
      expect(
        () => mergeCard(base, change('x', {'column': 9}, phone(2000))),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => mergeCard(base, change('x', {'title': '   '}, phone(2000))),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  group('diffToChange', () {
    test('содержит только изменённые поля', () {
      final edited =
          base.edit(hlc: pc(2000), title: 'Новое', column: BoardColumn.doing);
      final c = diffToChange(base, edited, changeId: 'ch')!;
      expect(c.changeId, 'ch');
      expect(c.id, cardId);
      expect(c.entity, cardEntity);
      expect(c.fields, {'title': 'Новое', 'column': 1, createdAtKey: 1000});
      expect(c.hlc, {'title': pc(2000), 'column': pc(2000)});
    });

    test('нет изменений — null', () {
      expect(diffToChange(base, base, changeId: 'ch'), isNull);
      // edit с теми же значениями не трогает метки.
      final same = base.edit(hlc: pc(2000), title: ' Задача ', deleted: false);
      expect(same, base);
      expect(diffToChange(base, same, changeId: 'ch'), isNull);
    });

    test('изменение, применённое на другой стороне, даёт ту же карточку', () {
      final edited = base.edit(
        hlc: pc(2000),
        description: 'Другое',
        pos: 'a0V',
        deleted: true,
      );
      final c = diffToChange(base, edited, changeId: 'ch')!;
      expect(mergeCard(base, c).card, edited);
    });

    test('полное состояние при before == null', () {
      final c = diffToChange(null, base, changeId: 'full')!;
      expect(c.fields, {
        'title': 'Задача',
        'description': 'Описание',
        'column': 0,
        'pos': 'a0',
        'deleted': false,
        createdAtKey: 1000,
      });
      expect(c.hlc.keys.toSet(), {for (final f in CardField.values) f.wire});
    });
  });
}

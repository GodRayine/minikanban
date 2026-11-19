import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minikanban/sync/client/sync_client.dart';
import 'package:minikanban/sync/client/sync_scheduler.dart';

void main() {
  late int runs;
  late SyncResult result;
  late SyncScheduler scheduler;

  setUp(() {
    runs = 0;
    result = SyncResult.ok;
    scheduler = SyncScheduler(
      sync: () async {
        runs++;
        return result;
      },
    );
  });

  test('при открытии — сразу, затем каждые 5 минут', () {
    fakeAsync((async) {
      scheduler.enterForeground();
      async.flushMicrotasks();
      expect(runs, 1);

      async.elapse(const Duration(minutes: 4, seconds: 59));
      expect(runs, 1);
      async.elapse(const Duration(seconds: 1));
      expect(runs, 2);
      async.elapse(const Duration(minutes: 10));
      expect(runs, 4);

      scheduler.enterBackground();
      async.elapse(const Duration(minutes: 30));
      expect(runs, 4);
    });
  });

  test('после локальной правки — через 3 с после последней', () {
    fakeAsync((async) {
      scheduler.enterForeground();
      async.flushMicrotasks();
      runs = 0;

      scheduler.notifyLocalChange();
      async.elapse(const Duration(seconds: 2));
      scheduler.notifyLocalChange();
      async.elapse(const Duration(seconds: 2));
      expect(runs, 0);
      async.elapse(const Duration(seconds: 1));
      expect(runs, 1);

      scheduler.enterBackground();
    });
  });

  test('возврат в приложение запускает синхронизацию', () {
    fakeAsync((async) {
      var refreshed = 0;
      final s = SyncScheduler(
        sync: () async {
          runs++;
          return result;
        },
        onForeground: () async => refreshed++,
      )..enterForeground();
      async.flushMicrotasks();
      s.enterBackground();
      expect((runs, refreshed), (1, 1));

      // Свёрнутое приложение правки не отправляет и таймеры не держит.
      s.notifyLocalChange();
      async.elapse(const Duration(minutes: 20));
      expect(runs, 1);

      s.enterForeground();
      async.flushMicrotasks();
      expect((runs, refreshed), (2, 2));
      s.enterBackground();
    });
  });

  test('ПК недоступен: повторы через 5, 15 и далее по 60 с', () {
    fakeAsync((async) {
      result = SyncResult.offline;
      scheduler.enterForeground();
      async.flushMicrotasks();
      expect(runs, 1);

      async.elapse(const Duration(seconds: 5));
      expect(runs, 2);
      async.elapse(const Duration(seconds: 14));
      expect(runs, 2);
      async.elapse(const Duration(seconds: 1));
      expect(runs, 3);
      async.elapse(const Duration(seconds: 60));
      expect(runs, 4);
      async.elapse(const Duration(seconds: 60));
      expect(runs, 5);

      // Связь появилась — повторы прекращаются, отсчёт сбрасывается.
      result = SyncResult.ok;
      async.elapse(const Duration(seconds: 60));
      expect(runs, 6);
      async.elapse(const Duration(seconds: 90));
      expect(runs, 6);

      result = SyncResult.offline;
      scheduler.notifyLocalChange();
      async.elapse(const Duration(seconds: 3));
      expect(runs, 7);
      async.elapse(const Duration(seconds: 5));
      expect(runs, 8);

      scheduler.enterBackground();
    });
  });

  test('«отвязано» и прочие блокировки не повторяются по бэкоффу', () {
    fakeAsync((async) {
      result = SyncResult.revoked;
      scheduler.enterForeground();
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 4));
      expect(runs, 1);
      scheduler.enterBackground();
    });
  });

  test('ручная синхронизация возвращает результат', () {
    fakeAsync((async) {
      SyncResult? got;
      scheduler.syncNow().then((r) => got = r);
      async.flushMicrotasks();
      expect(got, SyncResult.ok);
      expect(runs, 1);
      // В фоне повторы не планируются.
      result = SyncResult.offline;
      scheduler.syncNow();
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 2));
      expect(runs, 2);
    });
  });
}

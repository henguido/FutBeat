import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/qa_diagnostics.dart';

import 'calendar_cache_explore_test.dart' show calendarPayload;

void main() {
  test(
    'QA counters measure HTTP, shared flights and SQLite without values',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio();
      final diagnostics = QaDiagnostics();
      var requests = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            requests++;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            handler.resolve(
              Response(
                requestOptions: options,
                data: calendarPayload(),
                headers: Headers.fromMap({
                  'content-length': ['123'],
                }),
              ),
            );
          },
        ),
      );
      final policy = CalendarCachePolicy(prefetchRadius: 0);
      final repo = ApiRepository(dio, db, policy, null, diagnostics);
      final date = DateTime(2026, 10, 30);

      await Future.wait([repo.loadDate(date), repo.loadDate(date)]);
      expect(requests, 1);
      await repo.settleBackground();
      await repo.watchDate(date).first;
      final counts = diagnostics.snapshot()['counts'] as Map<String, int>;
      expect(counts['/v1/calendar:httpSuccess'], 1);
      expect(counts['/v1/calendar:sharedFlight'], 1);
      expect(counts['/v1/calendar:memoryHit'], 1);
      expect(
        (diagnostics.snapshot()['reportedContentLengthBytes']
            as Map<String, int>)['/v1/calendar:httpSuccess'],
        123,
      );
      final restarted = ApiRepository(dio, db, policy, null, diagnostics);
      await restarted.watchDate(date).first;
      expect(
        (diagnostics.snapshot()['counts']
            as Map<String, int>)['/v1/calendar:sqliteHit'],
        1,
      );
      expect(diagnostics.snapshot().toString(), isNot(contains('2026-10-30')));
      await db.close();
      dio.close(force: true);
    },
  );

  test('QA counters reject query values and identifiers', () {
    final diagnostics = QaDiagnostics();
    diagnostics.record('/v1/calendar?date=2026-10-30', 'httpSuccess');
    diagnostics.record('/v1/calendar', 'sqliteMiss');
    expect(diagnostics.snapshot().toString(), isNot(contains('2026-10-30')));
    expect((diagnostics.snapshot()['counts'] as Map<String, int>).length, 1);
  });
}

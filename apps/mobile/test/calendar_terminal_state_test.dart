import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';

import 'calendar_cache_explore_test.dart' show calendarPayload;
import 'mobile_history_performance_test.dart' show requestDate;

// A visible calendar date always ends in data or in an error with Retry,
// within a bounded deadline; it never loops in "loading".

DateTime today() => DateUtils.dateOnly(costaRicaNow());

Map<String, dynamic> pendingPayload() => {
  ...calendarPayload(),
  'matches': [],
  'coverage': {'partial': false, 'pending': true, 'retryAfterSeconds': 1},
  'freshness': {'stale': false, 'revalidating': true},
};

const fastPolicy = CalendarCachePolicy(
  visibleDeadline: Duration(milliseconds: 400),
  pendingPollMin: Duration(milliseconds: 20),
  pendingPollMax: Duration(milliseconds: 40),
  revalidateEvery: Duration(milliseconds: 60),
  revalidateMax: Duration(milliseconds: 400),
);

/// Answers from [respond] (a payload, or a DioExceptionType to fail).
({Dio dio, List<String> requested}) scriptedDio(
  Object Function(int call, String date) respond,
) {
  final dio = Dio();
  final requested = <String>[];
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (o, h) {
        final date = o.queryParameters['date'] as String;
        requested.add(date);
        final answer = respond(requested.length, date);
        if (answer is DioExceptionType) {
          h.reject(DioException(requestOptions: o, type: answer));
        } else {
          h.resolve(Response(requestOptions: o, data: answer));
        }
      },
    ),
  );
  return (dio: dio, requested: requested);
}

void main() {
  test('11. a date without cache loads in one request', () async {
    final net = scriptedDio((_, _) => calendarPayload(score: true));
    final values = await ApiRepository(
      net.dio,
      null,
      fastPolicy,
    ).watchDate(DateTime(2026, 8, 20)).toList();
    expect(values.single.matches.single.score, '1 - 1');
    expect(net.requested, hasLength(1));
    net.dio.close();
  });

  test(
    '12. no cache + persistent timeouts ends in an error, bounded in time',
    () async {
      final net = scriptedDio((_, _) => DioExceptionType.receiveTimeout);
      final watch = Stopwatch()..start();
      await expectLater(
        ApiRepository(
          net.dio,
          null,
          fastPolicy,
        ).watchDate(DateTime(2026, 8, 20), retryDelay: Duration.zero).toList(),
        throwsA(isA<DioException>()),
      );
      expect(net.requested, hasLength(fastPolicy.maxAttempts));
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      net.dio.close();
    },
  );

  test(
    '12b. a server that stays "pending" ends in an error at the deadline',
    () async {
      final net = scriptedDio((_, _) => pendingPayload());
      final values = <Snapshot>[];
      Object? error;
      await ApiRepository(net.dio, null, fastPolicy)
          .watchDate(DateTime(2026, 8, 20))
          .listen(values.add)
          .asFuture<void>()
          .catchError((Object e) => error = e);
      expect(values.first.calendarPending, true, reason: 'preparing state');
      expect(error, isA<TimeoutException>());
      expect(net.requested.length, lessThan(20), reason: 'bounded polling');
      net.dio.close();
    },
  );

  test(
    'pending, then the materialized day arrives within the deadline',
    () async {
      final net = scriptedDio(
        (call, _) => call < 3 ? pendingPayload() : calendarPayload(score: true),
      );
      final repo = ApiRepository(net.dio, null, fastPolicy);
      final values = await repo.watchDate(DateTime(2026, 8, 20)).toList();
      expect(values.first.calendarPending, true);
      expect(values.last.calendarPending, false);
      expect(values.last.matches.single.score, '1 - 1');
      // 20. Returning to the built day is a cache hit (pending was not cached).
      final again = await repo.watchDate(DateTime(2026, 8, 20)).toList();
      expect(again.single.matches.single.score, '1 - 1');
      expect(net.requested, hasLength(3));
      net.dio.close();
    },
  );

  test(
    '13/14. Retry works; a date without data is not re-polled on a timer',
    () async {
      var fail = true;
      final net = scriptedDio(
        (_, _) => fail
            ? DioExceptionType.connectionError
            : calendarPayload(score: true),
      );
      final container = ProviderContainer(
        overrides: [
          repositoryProvider.overrideWithValue(
            ApiRepository(net.dio, null, fastPolicy),
          ),
        ],
      );
      final date = DateTime(2026, 8, 20);
      final states = <AsyncValue<Snapshot>>[];
      final sub = container.listen(
        calendarSnapshotProvider(date),
        (_, next) => states.add(next),
        fireImmediately: true,
      );
      while (!states.last.hasError) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final afterError = net.requested.length;
      // Longer than several revalidation periods: no automatic loop.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(net.requested, hasLength(afterError));
      fail = false;
      container.invalidate(calendarSnapshotProvider(date));
      while (!(states.last.hasValue && !states.last.isLoading)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(states.last.value!.matches.single.score, '1 - 1');
      sub.close();
      container.dispose();
      net.dio.close();
    },
  );

  test('persistent failures back off background revalidation', () async {
    final net = scriptedDio((_, _) => DioExceptionType.connectionError);
    final repo = ApiRepository(net.dio, null, fastPolicy);
    final date = DateTime(2026, 8, 20);
    expect(repo.calendarRevalidateDelay(date), fastPolicy.revalidateEvery);
    for (var i = 0; i < 3; i++) {
      await repo
          .watchDate(date, retryDelay: Duration.zero)
          .toList()
          .catchError((_) => <Snapshot>[]);
    }
    expect(
      repo.calendarRevalidateDelay(date),
      fastPolicy.revalidateMax,
      reason: 'doubled per failure, capped',
    );
    net.dio.close();
  });

  test(
    '15/16. stale cache is shown at once and survives a failed refresh',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      await db.saveCalendarSnapshot(
        '2026-08-20',
        jsonEncode(calendarPayload(score: true)),
      );
      await db.customStatement('UPDATE calendar_snapshots SET saved_at = 0');
      final gate = Completer<void>();
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) async {
            await gate.future;
            h.reject(
              DioException(
                requestOptions: o,
                type: DioExceptionType.connectionError,
              ),
            );
          },
        ),
      );
      final values = <Snapshot>[];
      final done = Completer<void>();
      ApiRepository(dio, db, fastPolicy)
          .watchDate(DateTime(2026, 8, 20), retryDelay: Duration.zero)
          .listen(values.add, onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(values.single.matches.single.score, '1 - 1', reason: 'at once');
      gate.complete();
      await done.future;
      expect(values.last.stale, true);
      expect(values.every((v) => v.matches.single.score == '1 - 1'), true);
      dio.close();
      await db.close();
    },
  );

  for (final offset in [-30, 30]) {
    test('17/18. arbitrary date $offset days away: one request, then cached, '
        'no prefetch cascade outside the window', () async {
      final net = scriptedDio((_, _) => calendarPayload());
      final repo = ApiRepository(net.dio, null, fastPolicy);
      final date = today().add(Duration(days: offset));
      await repo.watchDate(date).toList();
      await repo.settleBackground();
      expect(net.requested, [requestDate(today(), offset)]);
      await repo.watchDate(date).toList();
      expect(net.requested, hasLength(1));
      net.dio.close();
    });
  }

  test(
    '19. switching away while a date is pending stops waiting safely',
    () async {
      final net = scriptedDio((_, _) => pendingPayload());
      final token = CancelToken();
      final values = <Snapshot>[];
      final done = Completer<void>();
      ApiRepository(net.dio, null, const CalendarCachePolicy())
          .watchDate(DateTime(2026, 8, 20), cancelToken: token)
          .listen(values.add, onDone: done.complete, onError: (_) {});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      token.cancel('switched date');
      await done.future.timeout(const Duration(seconds: 1));
      final after = net.requested.length;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        net.requested,
        hasLength(after),
        reason: 'no polling after leaving',
      );
      expect(values.single.calendarPending, true);
      net.dio.close();
    },
  );

  test('7. payload parse cost for a 1 000+ match day (measured)', () {
    final base = calendarPayload(score: true);
    final match = (base['matches'] as List).single as Map<String, dynamic>;
    final raw = {
      ...base,
      'matches': [
        for (var i = 0; i < 1084; i++) {...match, 'id': 'fb_match_p$i'},
      ],
    };
    final body = jsonEncode(raw);
    final watch = Stopwatch()..start();
    final snapshot = Snapshot(jsonDecode(body) as Map<String, dynamic>);
    final count = snapshot.matches.length;
    watch.stop();
    // Diagnostic, not a hard budget (machine dependent).
    // ignore: avoid_print
    print(
      'calendar parse: ${body.length ~/ 1024} KB, $count matches, '
      '${watch.elapsedMilliseconds} ms',
    );
    expect(count, 1084);
  });

  test('a hanging request cannot outlive the visible deadline', () async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {}));
    final watch = Stopwatch()..start();
    await expectLater(
      ApiRepository(
        dio,
        null,
        fastPolicy,
      ).watchDate(DateTime(2026, 8, 20)).toList(),
      throwsA(isA<TimeoutException>()),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    dio.close(force: true);
  });
}

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
import 'package:futbeat/shared/widgets.dart';

import 'calendar_cache_explore_test.dart' show calendarPayload;
import 'mobile_history_performance_test.dart' show requestDate;

// Calendar date switching is served from memory/disk first; neighbours are
// prepared in the background, one request at a time, inside a bounded window.

DateTime today() => DateUtils.dateOnly(costaRicaNow());

({Dio dio, List<String> requested}) countingDio({
  bool Function(String date)? fail,
}) {
  final dio = Dio();
  final requested = <String>[];
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (o, h) {
        final date = o.queryParameters['date'] as String;
        requested.add(date);
        if (fail?.call(date) ?? false) {
          h.reject(
            DioException(
              requestOptions: o,
              type: DioExceptionType.connectionError,
            ),
          );
        } else {
          h.resolve(
            Response(requestOptions: o, data: calendarPayload(score: true)),
          );
        }
      },
    ),
  );
  return (dio: dio, requested: requested);
}

void main() {
  test(
    '21. D -> D-1 is served from the prefetched cache with no request',
    () async {
      final net = countingDio();
      final repo = ApiRepository(net.dio);
      await repo.watchDate(today()).toList();
      await repo.settleBackground();
      final before = net.requested.length;
      final values = await repo
          .watchDate(today().subtract(const Duration(days: 1)))
          .toList();
      expect(net.requested, hasLength(before));
      expect(values.single.revalidating, false);
      expect(values.single.matches.single.score, '1 - 1');
      net.dio.close();
    },
  );

  test(
    '22. going back to a visited date needs no network, also after a restart',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final net = countingDio();
      final repo = ApiRepository(net.dio, db);
      final tomorrow = today().add(const Duration(days: 1));
      await repo.watchDate(tomorrow).toList();
      await repo.watchDate(today()).toList();
      await repo.settleBackground();
      final before = net.requested.length;
      expect(
        (await repo.watchDate(tomorrow).toList()).single.revalidating,
        false,
      );
      // A new repository (app restart) reads the day from disk within its TTL.
      final restarted = ApiRepository(net.dio, db);
      expect(
        (await restarted.watchDate(tomorrow).toList()).single.revalidating,
        false,
      );
      await restarted.settleBackground();
      expect(net.requested, hasLength(before));
      net.dio.close();
      await db.close();
    },
  );

  test(
    '23. neighbour prefetch is sequential, ordered and bounded to the window',
    () async {
      final dio = Dio();
      final requested = <String>[];
      var inFlight = 0;
      var maxInFlight = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) async {
            requested.add(o.queryParameters['date'] as String);
            maxInFlight = ++inFlight > maxInFlight ? inFlight : maxInFlight;
            await Future<void>.delayed(const Duration(milliseconds: 5));
            inFlight--;
            h.resolve(Response(requestOptions: o, data: calendarPayload()));
          },
        ),
      );
      final repo = ApiRepository(dio);
      await repo.watchDate(today()).toList();
      await repo.settleBackground();
      expect(maxInFlight, 1);
      expect(requested, [
        for (final o in [0, 1, -1, 2, -2]) requestDate(today(), o),
      ]);
      // A date far from today does not start a history cascade.
      requested.clear();
      await repo.watchDate(today().subtract(const Duration(days: 30))).toList();
      await repo.settleBackground();
      expect(requested, [requestDate(today(), -30)]);
      // Near the end of the forward window only in-window days are prepared.
      requested.clear();
      await repo.watchDate(today().add(const Duration(days: 7))).toList();
      await repo.settleBackground();
      expect(requested, [
        for (final o in [7, 6, 5]) requestDate(today(), o),
      ]);
      dio.close();
    },
  );

  test(
    '23b. a newer visible date supersedes the previous prefetch chain',
    () async {
      final dio = Dio();
      final requested = <String>[];
      final gate = Completer<void>();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) async {
            final date = o.queryParameters['date'] as String;
            requested.add(date);
            if (date == requestDate(today(), 1)) await gate.future;
            h.resolve(Response(requestOptions: o, data: calendarPayload()));
          },
        ),
      );
      final repo = ApiRepository(dio);
      await repo.watchDate(today()).toList();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      // The user moves on while D+1 is still being prefetched.
      await repo.watchDate(today().add(const Duration(days: 4))).toList();
      gate.complete();
      await repo.settleBackground();
      expect(requested.take(3), [
        requestDate(today(), 0),
        requestDate(today(), 1),
        requestDate(today(), 4),
      ]);
      // Old chain (D-1, D+2, D-2) is abandoned; the new one follows D+4.
      expect(requested.skip(3), [
        for (final o in [5, 3, 6, 2]) requestDate(today(), o),
      ]);
      dio.close();
    },
  );

  test(
    'closing the visible date never cancels a shared prefetch of that date',
    () async {
      final dio = Dio();
      final gate = Completer<void>();
      final tokens = <CancelToken?>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) async {
            tokens.add(o.cancelToken);
            await gate.future;
            if (o.cancelToken?.isCancelled == true) return;
            h.resolve(Response(requestOptions: o, data: calendarPayload()));
          },
        ),
      );
      final repo = ApiRepository(dio);
      final date = DateTime(2026, 8, 20);
      final visible = CancelToken();
      final values = <Snapshot>[];
      final done = Completer<void>();
      repo
          .watchDate(date, cancelToken: visible)
          .listen(values.add, onDone: done.complete, onError: (_) {});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final prefetch = repo.prefetchDate(date);
      visible.cancel('screen closed');
      await done.future;
      gate.complete();
      await prefetch;
      expect(tokens, hasLength(1), reason: 'one shared request');
      expect(tokens.single!.isCancelled, false);
      expect(repo.peekDate(date), isNotNull);
      dio.close();
    },
  );

  test('the only waiter leaving cancels the request', () async {
    final dio = Dio();
    final tokens = <CancelToken?>[];
    dio.interceptors.add(
      InterceptorsWrapper(onRequest: (o, h) => tokens.add(o.cancelToken)),
    );
    final repo = ApiRepository(dio);
    final visible = CancelToken();
    final done = Completer<void>();
    repo
        .watchDate(DateTime(2026, 8, 20), cancelToken: visible)
        .listen((_) {}, onDone: done.complete, onError: (_) {});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    visible.cancel('closed');
    await done.future;
    expect(tokens.single!.isCancelled, true);
    dio.close(force: true);
  });

  test('24. a failed refresh keeps the day visible and prefetch failures evict nothing', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final value = requestDate(today(), 0);
    await db.saveCalendarSnapshot(
      value,
      jsonEncode(calendarPayload(score: true)),
    );
    await db.customStatement('UPDATE calendar_snapshots SET saved_at = 0');
    final net = countingDio(fail: (_) => true);
    final repo = ApiRepository(net.dio, db);
    final values = await repo
        .watchDate(today(), retryDelay: Duration.zero)
        .toList();
    expect(values.every((v) => v.matches.single.score == '1 - 1'), true);
    expect(values.last.stale, true);
    await repo.prefetchDate(today());
    expect(repo.peekDate(today()), isNotNull);
    net.dio.close();
    await db.close();
  });

  testWidgets(
    '25. switching to a date held in memory paints it in the first frame',
    (tester) async {
      final net = countingDio();
      final repo = ApiRepository(net.dio);
      final date = DateTime(2026, 8, 20);
      await tester.runAsync(() => repo.loadDate(date));
      final frames = <(bool, String)>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            repositoryProvider.overrideWithValue(repo),
            liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: CalendarDataView(
                date: date,
                builder: (data, loading, failed) {
                  final label = data.matches.isEmpty
                      ? 'empty'
                      : data.matches.single.score;
                  frames.add((loading, label));
                  return Text(label);
                },
              ),
            ),
          ),
        ),
      );
      expect(frames.first, (false, '1 - 1'), reason: 'no loading flash');
      expect(find.text('1 - 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      net.dio.close();
    },
  );

  testWidgets('26. loading shows only without cache, never a false empty day', (
    tester,
  ) async {
    final stream = StreamController<Snapshot>();
    final flags = <(bool, bool)>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          calendarSnapshotProvider.overrideWith((ref, date) => stream.stream),
          liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: CalendarDataView(
              date: DateTime(2026, 8, 20),
              builder: (data, loading, failed) {
                flags.add((loading, failed));
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    expect(flags.last, (true, false), reason: 'no cache yet');
    // Stream event, then provider notification, then the rebuilt frame.
    Future<void> settle() async {
      await tester.pump();
      await tester.pump();
    }

    Map<String, dynamic> empty() => {...calendarPayload(), 'matches': []};
    stream.add(Snapshot(empty()).withFreshness(revalidating: true));
    await settle();
    expect(flags.last, (true, false), reason: 'empty cached day revalidating');
    stream.add(Snapshot(calendarPayload()).withFreshness(revalidating: true));
    await settle();
    expect(flags.last, (false, false), reason: 'cached matches: no loading');
    stream.add(Snapshot(empty()));
    await settle();
    expect(flags.last, (false, false), reason: 'confirmed empty day');
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(stream.close);
  });
}

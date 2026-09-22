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
import 'package:futbeat/features/explore/explore_screen.dart';
import 'package:futbeat/features/matches/matches_screen.dart';
import 'package:futbeat/shared/widgets.dart';

import 'mobile_history_performance_test.dart' show payload;

Map<String, dynamic> calendarPayload({
  bool score = false,
  bool future = false,
}) {
  final raw = jsonDecode(jsonEncode(payload())) as Map<String, dynamic>;
  raw['freshness'] = {'stale': false};
  raw['coverage'] = {'partial': false};
  (raw['matches'] as List).single['score'] = score
      ? {'home': 1, 'away': 1}
      : null;
  (raw['matches'] as List).single['hasPlayedEvidence'] = score;
  if (future) {
    (raw['matches'] as List).single['startTime'] = DateTime.now()
        .toUtc()
        .add(const Duration(days: 1))
        .toIso8601String();
  }
  return raw;
}

void main() {
  test('calendar refresh requests remain single-flight without request cache headers', () async {
    final dio = Dio();
    final entered = Completer<void>();
    final release = Completer<void>();
    var calls = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) async {
          calls++;
          expect(o.headers.containsKey('Cache-Control'), false);
          entered.complete();
          await release.future;
          h.resolve(
            Response(requestOptions: o, data: calendarPayload(score: true)),
          );
        },
      ),
    );
    final repo = ApiRepository(dio);
    final date = DateTime(2026, 8, 20);
    repo.refreshDate(date);
    final first = repo.loadDate(date);
    await entered.future;
    final second = repo.loadDate(date);
    release.complete();
    final results = await Future.wait([first, second]);
    expect(calls, 1);
    expect(results.every((s) => s.matches.single.score == '1 - 1'), true);
    dio.close();
  });
  test('stale null score emits immediately then fresh 1-1 replaces memory and Drift', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.saveCalendarSnapshot('2026-08-20', jsonEncode(calendarPayload()));
    await db.customStatement('UPDATE calendar_snapshots SET saved_at = 0');
    final gate = Completer<void>();
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) async {
          await gate.future;
          h.resolve(
            Response(requestOptions: o, data: calendarPayload(score: true)),
          );
        },
      ),
    );
    final repo = ApiRepository(dio, db);
    final values = <Snapshot>[];
    final done = Completer<void>();
    final sub = repo
        .watchDate(DateTime(2026, 8, 20))
        .listen(values.add, onDone: done.complete);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(values.single.matches.single.score, '—');
    expect(values.single.stale, false);
    expect(values.single.revalidating, true);
    gate.complete();
    await done.future;
    expect(values.last.matches.single.score, '1 - 1');
    expect(values.last.stale, false);
    expect(values.last.revalidating, false);
    expect(
      Snapshot(
        jsonDecode((await db.readCalendarSnapshot('2026-08-20'))!)
            as Map<String, dynamic>,
      ).matches.single.score,
      '1 - 1',
    );
    await sub.cancel();
    dio.close();
    await db.close();
  });
  test('failed refresh keeps cache then bounded retry clears real stale after success', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.saveCalendarSnapshot('2026-08-20', jsonEncode(calendarPayload()));
    await db.customStatement('UPDATE calendar_snapshots SET saved_at = 0');
    final dio = Dio();
    var calls = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) {
          calls++;
          if (calls == 1) {
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
    final values = await ApiRepository(
      dio,
      db,
    ).watchDate(DateTime(2026, 8, 20), retryDelay: Duration.zero).toList();
    expect(calls, 2);
    expect(values.map((v) => v.stale), [false, true, false]);
    expect(values[1].matches.single.score, '—');
    expect(values.last.matches.single.score, '1 - 1');
    dio.close();
    await db.close();
  });
  test('pull refresh bypasses recently persisted cache without a dead request header', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.saveCalendarSnapshot('2026-08-20', jsonEncode(calendarPayload()));
    final dio = Dio();
    var calls = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) {
          calls++;
          expect(o.headers.containsKey('Cache-Control'), false);
          h.resolve(
            Response(requestOptions: o, data: calendarPayload(score: true)),
          );
        },
      ),
    );
    final repo = ApiRepository(dio, db);
    expect(
      (await repo.watchDate(DateTime(2026, 8, 20)).toList())
          .single
          .matches
          .single
          .score,
      '—',
    );
    repo.refreshDate(DateTime(2026, 8, 20));
    expect(
      (await repo.watchDate(DateTime(2026, 8, 20)).toList())
          .last
          .matches
          .single
          .score,
      '1 - 1',
    );
    expect(calls, 1);
    dio.close();
    await db.close();
  });
  testWidgets(
    'stale banner clears on success without hiding calendar content',
    (tester) async {
      final stream = StreamController<Snapshot>();
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
                builder: (data, loading, failed) => Text(
                  data.matches.isEmpty ? 'Loading' : data.matches.single.score,
                ),
              ),
            ),
          ),
        ),
      );
      stream.add(Snapshot(calendarPayload()).asStale());
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Los datos pueden estar desactualizados'),
        findsOneWidget,
      );
      stream.add(Snapshot(calendarPayload(score: true)));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Los datos pueden estar desactualizados'),
        findsNothing,
      );
      expect(find.text('1 - 1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(stream.close);
    },
  );
  testWidgets(
    'future scheduled card shows kickoff, historical score partial and terminal final',
    (tester) async {
      final data = Snapshot(calendarPayload(future: true));
      expect(data.matches.single.showKickoff, true);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [followsProvider.overrideWith((ref) => Stream.value({}))],
          child: MaterialApp(
            home: Scaffold(body: MatchCard(data.matches.single, data)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('—'), findsNothing);
      expect(find.text('Hora Costa Rica'), findsOneWidget);
      final history = Snapshot(calendarPayload(score: true)).matches.single;
      expect(history.statusLabel, 'Marcador parcial');
      expect(
        FootballMatch({...history.json, 'status': 'VERIFIED'}).statusLabel,
        'Finalizado',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'Explore loads suggestions not empty search, retains results and cancels previous query',
    (tester) async {
      final dio = Dio();
      final requests = <RequestOptions>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            requests.add(o);
            if (o.path == '/v1/explore') {
              h.resolve(
                Response(
                  requestOptions: o,
                  data: {...calendarPayload(), 'matches': []},
                ),
              );
            }
            // Searches remain pending so cancellation and previous results are observable.
          },
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            repositoryProvider.overrideWithValue(ApiRepository(dio)),
            followsProvider.overrideWith((ref) => Stream.value({})),
          ],
          child: const MaterialApp(home: ExploreScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(requests.map((r) => r.path), ['/v1/explore']);
      expect(find.text('Competiciones destacadas'), findsOneWidget);
      expect(find.text('Equipos sugeridos'), findsOneWidget);
      expect(find.text('COSTA RICA'), findsNothing);
      await tester.enterText(find.byType(TextField), 'm');
      await tester.pump(const Duration(milliseconds: 300));
      expect(requests.length, 1);
      await tester.enterText(find.byType(TextField), 'manchester');
      await tester.pump(const Duration(milliseconds: 200));
      expect(requests.length, 1);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 10));
      expect(requests.length, 2);
      expect(requests.last.queryParameters['q'], 'manchester');
      expect(find.text('Home'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.enterText(find.byType(TextField), 'london');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 10));
      expect(requests[1].cancelToken!.isCancelled, true);
      expect(requests.last.queryParameters['q'], 'london');
      expect(find.text('Home'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      dio.close(force: true);
    },
  );
  test(
    'search short cache ignores legacy country and suggestions reuse memory',
    () async {
      final dio = Dio();
      var calls = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            calls++;
            expect(o.queryParameters.containsKey('country'), false);
            h.resolve(
              Response(
                requestOptions: o,
                data: {...calendarPayload(), 'matches': []},
              ),
            );
          },
        ),
      );
      final repo = ApiRepository(dio);
      await repo.loadExplore();
      await repo.loadExplore();
      expect(calls, 1);
      await repo.searchCatalog('Manchester', 'CR');
      await repo.searchCatalog('manchester', 'ES');
      expect(calls, 2);
      dio.close();
    },
  );
}

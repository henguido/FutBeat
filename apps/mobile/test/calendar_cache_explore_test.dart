import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
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

class _DelayedCalendarReadDatabase extends AppDatabase {
  _DelayedCalendarReadDatabase() : super(NativeDatabase.memory());

  final releaseRead = Completer<void>();
  final readStarted = Completer<void>();

  @override
  Future<CalendarSnapshot?> readCalendarEntry(String date) async {
    final row = await super.readCalendarEntry(date);
    readStarted.complete();
    await releaseRead.future;
    return row;
  }
}

void main() {
  test(
    'slow SQLite read cannot replace a newer HTTP calendar answer',
    () async {
      final db = _DelayedCalendarReadDatabase();
      final old = calendarPayload();
      old['updatedAt'] = '2026-08-20T18:00:00Z';
      await db.saveCalendarSnapshot('2026-08-20', jsonEncode(old));
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            final fresh = calendarPayload(score: true);
            fresh['updatedAt'] = '2026-08-20T20:00:00Z';
            h.resolve(Response(requestOptions: o, data: fresh));
          },
        ),
      );
      final repo = ApiRepository(
        dio,
        db,
        const CalendarCachePolicy(prefetchRadius: 0),
      );
      final date = DateTime(2026, 8, 20);
      final staleRead = repo.watchDate(date).toList();
      await db.readStarted.future;
      expect((await repo.loadDate(date)).matches.single.score, '1 - 1');
      db.releaseRead.complete();
      expect((await staleRead).first.matches.single.score, '1 - 1');
      expect(repo.peekDate(date)?.matches.single.score, '1 - 1');
      await repo.settleBackground();
      dio.close();
      await db.close();
    },
  );

  test(
    'visible calendar timer stops on pause and rechecks on resume',
    () async {
      final dio = Dio();
      var calls = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            calls++;
            handler.resolve(
              Response(requestOptions: options, data: calendarPayload()),
            );
          },
        ),
      );
      final repo = ApiRepository(
        dio,
        null,
        const CalendarCachePolicy(
          todayTtl: Duration.zero,
          prefetchRadius: 0,
          revalidateEvery: Duration(milliseconds: 200),
        ),
      );
      final container = ProviderContainer(
        overrides: [repositoryProvider.overrideWithValue(repo)],
      );
      final now = costaRicaNow();
      final date = DateTime(now.year, now.month, now.day);
      final listener = container.listen(
        calendarSnapshotProvider(date),
        (_, _) {},
      );
      await container.read(calendarSnapshotProvider(date).future);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, 1);
      container.read(sportsAppActiveProvider).value = false;
      repo.setAppActive(false);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(calls, 1);
      repo.refreshDate(date);
      repo.setAppActive(true);
      container.read(sportsAppActiveProvider).value = true;
      for (var i = 0; i < 20 && calls < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(calls, 2);
      listener.close();
      container.dispose();
      dio.close();
    },
  );

  test(
    'complete historical day keeps past TTL despite revalidating hint',
    () async {
      final dio = Dio();
      var calls = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            calls++;
            final raw = calendarPayload();
            raw['freshness'] = {'stale': false, 'revalidating': true};
            raw['coverage'] = {
              'partial': false,
              'calendar': {'complete': true},
            };
            handler.resolve(Response(requestOptions: options, data: raw));
          },
        ),
      );
      final repo = ApiRepository(
        dio,
        null,
        const CalendarCachePolicy(recoveringTtl: Duration.zero),
      );
      final date = costaRicaNow().subtract(const Duration(days: 1));
      await repo.loadDate(date);
      await repo.watchDate(date).toList();
      expect(calls, 1);
      dio.close();
    },
  );

  test(
    'calendar performs zero reads while backgrounded and resumes on demand',
    () async {
      final dio = Dio();
      var calls = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            calls++;
            handler.resolve(
              Response(requestOptions: options, data: calendarPayload()),
            );
          },
        ),
      );
      final repo = ApiRepository(dio);
      final today = costaRicaNow();
      final date = DateTime(today.year, today.month, today.day);
      repo.setAppActive(false);
      expect(await repo.watchDate(date).toList(), isEmpty);
      await repo.prefetchDate(date);
      expect(calls, 0);
      repo.setAppActive(true);
      expect(await repo.watchDate(date).toList(), isNotEmpty);
      expect(calls, greaterThanOrEqualTo(1));
      dio.close();
    },
  );

  test(
    'older calendar response cannot replace newer memory and disk',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio();
      var calls = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            calls++;
            final raw = calendarPayload(score: calls == 1);
            raw['updatedAt'] = calls == 1
                ? '2026-08-20T20:00:00Z'
                : '2026-08-20T19:00:00Z';
            h.resolve(Response(requestOptions: o, data: raw));
          },
        ),
      );
      final repo = ApiRepository(dio, db);
      final date = DateTime(2026, 8, 20);
      expect((await repo.loadDate(date)).matches.single.score, '1 - 1');
      await repo.settleBackground();
      expect((await repo.loadDate(date)).matches.single.score, '1 - 1');
      await repo.settleBackground();
      expect(repo.peekDate(date)?.matches.single.score, '1 - 1');
      final persisted = await db.readCalendarSnapshot('2026-08-20');
      expect(
        Snapshot(jsonDecode(persisted!) as Map<String, dynamic>)
            .matches
            .single
            .score,
        '1 - 1',
      );
      expect(calls, 2);
      dio.close();
      await db.close();
    },
  );

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
  test(
    'the refresh line follows our own request, not the server rebuild flag',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      await db.saveCalendarSnapshot(
        '2026-08-20',
        jsonEncode(calendarPayload()),
      );
      await db.customStatement('UPDATE calendar_snapshots SET saved_at = 0');
      final gate = Completer<void>();
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) async {
            await gate.future;
            // Big day: the server serves its previous build while it rebuilds.
            final raw = calendarPayload(score: true);
            raw['freshness'] = {'stale': false, 'revalidating': true};
            h.resolve(Response(requestOptions: o, data: raw));
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
      // Our request is in flight: the line shows.
      expect(values.single.revalidating, true);
      gate.complete();
      await done.future;
      // Answered: the line stops, the data is the new one.
      expect(values.last.matches.single.score, '1 - 1');
      expect(values.last.revalidating, false);
      expect(values.last.stale, false);
      // The server flag still shortens the next revalidation (raw in memory).
      expect(repo.peekDate(DateTime(2026, 8, 20))?.revalidating, true);
      await repo.settleBackground();
      await sub.cancel();
      dio.close();
      await db.close();
    },
  );

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
    await repo.settleBackground();
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
    'stale calendar content has no technical banner; active refresh has a thin indicator',
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
        findsNothing,
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
      stream.add(
        Snapshot(calendarPayload())
            .withFreshness(stale: true, revalidating: true),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.textContaining('Desliza para actualizar'), findsNothing);
      stream.add(Snapshot(calendarPayload(score: true)));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Los datos pueden estar desactualizados'),
        findsNothing,
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('1 - 1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(stream.close);
    },
  );
  testWidgets('DataView keeps stale content without technical copy', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          effectiveSnapshotProvider.overrideWith(
            (ref) => AsyncData(Snapshot(calendarPayload()).asStale()),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: DataView(builder: (data) => Text(data.matches.single.id)),
          ),
        ),
      ),
    );
    expect(
      find.textContaining('Los datos pueden estar desactualizados'),
      findsNothing,
    );
    expect(find.textContaining('Desliza para actualizar'), findsNothing);
    expect(find.text('fb_match_test'), findsOneWidget);
  });
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
      final countries = StreamController<CountryPreference>();
      final requests = <RequestOptions>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            // Player suggestions are a separate, optional request.
            if (o.path == '/v1/player-suggestions') {
              h.resolve(
                Response(
                  requestOptions: o,
                  data: {...calendarPayload(), 'matches': [], 'players': []},
                ),
              );
              return;
            }
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
            preferenceProvider.overrideWith((ref) => countries.stream),
          ],
          child: const MaterialApp(home: ExploreScreen()),
        ),
      );
      countries.add(
        const CountryPreference(
          detectedCountry: 'CR',
          selectedCountry: null,
          bootstrapDismissed: true,
        ),
      );
      await tester.pumpAndSettle();
      // Global and country suggestions are requested in parallel.
      expect(requests.map((r) => r.path), ['/v1/explore', '/v1/explore']);
      expect(requests.first.queryParameters, isEmpty);
      expect(requests[1].queryParameters['country'], 'CR');
      expect(find.text('Competiciones'), findsOneWidget);
      expect(find.text('Equipos sugeridos'), findsOneWidget);
      expect(find.text('COSTA RICA'), findsNothing);
      await tester.enterText(find.byType(TextField), 'm');
      await tester.pump(const Duration(milliseconds: 300));
      expect(requests.length, 2);
      await tester.enterText(find.byType(TextField), 'manchester');
      await tester.pump(const Duration(milliseconds: 200));
      expect(requests.length, 2);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 10));
      expect(requests.length, 3);
      expect(requests.last.queryParameters['q'], 'manchester');
      expect(requests.last.queryParameters['country'], 'CR');
      // Discovery recommendations never leak into the query state while its
      // own response is pending.
      expect(find.text('Home'), findsNothing);
      expect(find.text('Buscando “manchester”…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'london');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 10));
      expect(requests[2].cancelToken!.isCancelled, true);
      expect(requests.last.queryParameters['q'], 'london');
      countries.add(
        const CountryPreference(
          detectedCountry: 'CR',
          selectedCountry: 'ES',
          bootstrapDismissed: true,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(requests[3].cancelToken!.isCancelled, true);
      expect(requests.last.queryParameters['country'], 'ES');
      expect(find.text('Home'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.runAsync(countries.close);
      dio.close(force: true);
    },
  );
  test(
    'search preserves country in HTTP and cache while suggestions reuse memory',
    () async {
      final dio = Dio();
      var calls = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            calls++;
            if (o.path == '/v1/search') {
              expect(o.queryParameters['country'], anyOf('CR', 'ES'));
            }
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
      expect(calls, 3);
      dio.close();
    },
  );
}

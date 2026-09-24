import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/matches_screen.dart';
import 'package:futbeat/features/matches/match_screen.dart';

/// The `date` query parameter the repository sends for [date] + [offset] days.
String requestDate(DateTime date, int offset) {
  final day = DateTime(date.year, date.month, date.day + offset);
  return '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';
}

Map<String, dynamic> payload({bool table = false}) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-08-20T20:00:00Z',
  'competitions': [
    {'id': 'fb_comp_test', 'name': 'League', 'relevanceScore': 970},
  ],
  'teams': [
    {'id': 'fb_team_home', 'name': 'Home'},
    {'id': 'fb_team_away', 'name': 'Away'},
  ],
  'players': [],
  'standings': table
      ? [
          {
            'competitionId': 'fb_comp_test',
            'rows': [
              {
                'teamId': 'fb_team_home',
                'played': 1,
                'won': 1,
                'drawn': 0,
                'lost': 0,
                'gf': 2,
                'ga': 1,
                'points': 3,
              },
            ],
          },
        ]
      : [],
  'matches': [
    {
      'id': 'fb_match_test',
      'competitionId': 'fb_comp_test',
      'homeTeamId': 'fb_team_home',
      'awayTeamId': 'fb_team_away',
      'startTime': '2026-08-20T18:00:00Z',
      'status': 'SCHEDULED',
      'score': {'home': 2, 'away': 1},
      'hasPlayedEvidence': true,
    },
  ],
};

class _OfflineDetailRepository extends ApiRepository {
  _OfflineDetailRepository() : super(Dio());
  int loads = 0;
  int reads = 0;
  @override
  Future<MatchDetail> loadMatchDetail(
    String id, {
    CancelToken? cancelToken,
  }) async {
    loads++;
    throw StateError('offline');
  }

  @override
  Future<MatchDetail> readMatchDetail(
    String id, {
    CancelToken? cancelToken,
  }) async {
    reads++;
    throw StateError('offline');
  }
}

void main() {
  testWidgets(
    'offline detail keeps summary, expires to empty and tabs never restart polling',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      await tester.runAsync(() async {
        await db.customSelect('select 1').get();
      });
      final repo = _OfflineDetailRepository();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          repositoryProvider.overrideWithValue(repo),
          matchContextSnapshotProvider.overrideWith(
            (ref, id) async => Snapshot(payload()),
          ),
          followsProvider.overrideWith((ref) => Stream.value({})),
          liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: MatchScreen(
              id: 'fb_match_test',
              initialData: Snapshot(payload()),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('2 - 1'), findsOneWidget);
      await tester.tap(find.text('Estadísticas'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('Sin estadísticas'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      await tester.tap(find.text('Alineación'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('Sin alineaciones'), findsNothing);
      // Bounded schedule: one read-only refresh per step (5, 10, 20, 40 s),
      // then the pending state ends in simple empty states.
      for (var second = 0; second < 90; second++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pumpAndSettle();
      expect(find.text('Sin alineaciones'), findsOneWidget);
      await tester.tap(find.text('Estadísticas'));
      await tester.pumpAndSettle();
      expect(find.text('Sin estadísticas'), findsOneWidget);
      expect(repo.loads, 1);
      expect(repo.reads, 4);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await tester.pump(const Duration(seconds: 120));
      expect(repo.reads, 4);
      await tester.runAsync(db.close);
    },
  );

  test('real redirected SQL calendar is a valid navigable Snapshot', () {
    final data = Snapshot(
      jsonDecode(
        File('test/fixtures/redirected_calendar.json').readAsStringSync(),
      ) as Map<String, dynamic>,
    );
    final match = data.matches.single;
    expect(match.homeId, 'fb_team_home_0');
    expect(match.awayId, 'fb_team_away_0');
    expect(match.competitionId, 'fb_comp_perf');
    expect(data.team(match.homeId)?.name, 'Team home 0');
    expect(data.team(match.awayId)?.name, 'Team away 0');
    expect(data.competition(match.competitionId)?.name, 'Competition');
    expect(data.forMatch(match.id).matches.single.id, match.id);
  });

  test(
    'failed central detail retries; accepted and concurrent requests dedupe',
    () async {
      final dio = Dio();
      var central = 0;
      final accepted = Completer<void>();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) async {
            if (o.queryParameters['request'] != '0') {
              central++;
              if (central == 1) {
                h.reject(
                  DioException(
                    requestOptions: o,
                    type: DioExceptionType.connectionTimeout,
                  ),
                );
                return;
              }
              await accepted.future;
            }
            h.resolve(
              Response(
                requestOptions: o,
                data: {
                  'matchId': 'fb_match_test',
                  'pending': true,
                  'available': false,
                },
              ),
            );
          },
        ),
      );
      final repo = ApiRepository(dio);
      await expectLater(
        repo.loadMatchDetail('fb_match_test'),
        throwsA(isA<DioException>()),
      );
      final second = repo.loadMatchDetail('fb_match_test');
      final concurrent = repo.loadMatchDetail('fb_match_test');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(central, 2);
      accepted.complete();
      await Future.wait([second, concurrent]);
      await repo.loadMatchDetail('fb_match_test');
      expect(central, 2);
      dio.close();
    },
  );

  for (final slow in [false, true]) {
    test('initial detail failure keeps finite pending window (slow=$slow)', () async {
      final dio = Dio();
      var reads = 0;
      final tokens = <CancelToken>[];
      final elapsed = Stopwatch()..start();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            reads++;
            expect(o.queryParameters['request'], '0');
            if (slow) {
              tokens.add(o.cancelToken!);
              return; // Simulate a read that never completes, until cancelled.
            }
            h.reject(
              DioException(
                requestOptions: o,
                type: DioExceptionType.connectionError,
              ),
            );
          },
        ),
      );
      final container = ProviderContainer(
        overrides: [
          repositoryProvider.overrideWithValue(ApiRepository(dio)),
          detailPollIntervalProvider.overrideWithValue(
            Duration(milliseconds: slow ? 100 : 50),
          ),
          if (slow)
            detailReadTimeoutProvider.overrideWithValue(
              const Duration(milliseconds: 300),
            ),
        ],
      );
      final values = <MatchDetail>[];
      final done = Completer<void>();
      final watch = container.listen(matchDetailProvider('fb_match_test'), (
        a,
        b,
      ) {
        final value = b.asData?.value;
        if (value != null) {
          values.add(value);
          if (!value.pending && !done.isCompleted) done.complete();
        }
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(values, isNotEmpty);
      expect(values.every((value) => value.pending), true);
      await done.future.timeout(const Duration(seconds: 17));
      // Initial read + one read-only refresh per bounded schedule step.
      expect(reads, 5);
      expect(values.last.pending, false);
      expect(values.last.statistics, isEmpty);
      expect(values.last.homeStarters, isEmpty);
      if (slow) {
        expect(tokens.every((token) => token.isCancelled), true);
        // Every slow read is cut at the read timeout; the schedule ends.
        // 300 ms initial + (100+300) + (200+300) + (400+300) + (800+300).
        expect(
          elapsed.elapsed,
          greaterThanOrEqualTo(const Duration(milliseconds: 3000)),
        );
        expect(elapsed.elapsed, lessThan(const Duration(seconds: 6)));
      }
      watch.close();
      container.dispose();
      dio.close();
    });
  }

  test('disposing detail stops further phone polling', () async {
    final dio = Dio();
    var requests = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) {
          requests++;
          h.resolve(
            Response(
              requestOptions: o,
              data: {
                'matchId': 'fb_match_test',
                'available': false,
                'pending': true,
              },
            ),
          );
        },
      ),
    );
    final container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(ApiRepository(dio)),
        detailPollIntervalProvider.overrideWithValue(
          const Duration(milliseconds: 100),
        ),
      ],
    );
    final ready = Completer<void>();
    final subscription = container.listen(
      matchDetailProvider('fb_match_test'),
      (a, b) {
        if (requests >= 2 && b.asData != null && !ready.isCompleted) {
          ready.complete();
        }
      },
    );
    await ready.future;
    subscription.close();
    container.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(requests, 2);
    dio.close();
  });

  test(
    'stored historical snapshot is emitted before a blocked refresh',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio();
      final gate = Completer<void>();
      var requests = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            requests++;
            await gate.future;
            handler.resolve(Response(requestOptions: options, data: payload()));
          },
        ),
      );
      await db.saveCalendarSnapshot('2026-08-20', jsonEncode(payload()));
      await db.customStatement("UPDATE calendar_snapshots SET saved_at = 0");
      final values = <Snapshot>[];
      final stream = ApiRepository(dio, db).watchDate(DateTime(2026, 8, 20));
      final complete = Completer<void>();
      final subscription = stream.listen(values.add, onDone: complete.complete);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(values, hasLength(1));
      expect(requests, 1);
      gate.complete();
      await complete.future;
      expect(values, hasLength(2));
      expect(requests, 1); // No historical prefetch cascade.
      await subscription.cancel();
      dio.close();
      await db.close();
    },
  );

  test('today yesterday today: one visible fetch, neighbours prefetched once in order', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final dio = Dio();
    final requested = <String>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) {
          requested.add(o.queryParameters['date'] as String);
          h.resolve(Response(requestOptions: o, data: payload()));
        },
      ),
    );
    final repository = ApiRepository(dio, db);
    final today = DateUtils.dateOnly(costaRicaNow());
    String day(int offset) => requestDate(today, offset);
    await repository.watchDate(today).toList();
    await repository.settleBackground();
    // Sequential D+1, D-1, D+2, D-2 (never a burst of parallel requests).
    expect(requested, [day(0), day(1), day(-1), day(2), day(-2)]);
    await repository
        .watchDate(today.subtract(const Duration(days: 1)))
        .toList();
    await repository.watchDate(today).toList();
    await repository.settleBackground();
    expect(requested, hasLength(5));
    // Reopening the repository also reuses persisted historical freshness.
    final restarted = ApiRepository(dio, db);
    await restarted.watchDate(today.subtract(const Duration(days: 1))).toList();
    await restarted.settleBackground();
    expect(requested, hasLength(5));
    dio.close();
    await db.close();
  });

  for (final arrives in [false, true]) {
    test(
      'detail window is bounded and preserves arriving data (arrives=$arrives)',
      () async {
        final dio = Dio();
        var requests = 0;
        var demands = 0;
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (o, h) {
              requests++;
              if (o.queryParameters['request'] != '0') demands++;
              final ready = arrives && requests >= 3;
              h.resolve(
                Response(
                  requestOptions: o,
                  data: {
                    'matchId': 'fb_match_test',
                    'pending': !ready,
                    'available': ready,
                    'statistics': ready
                        ? [
                            {'label': 'Posesión', 'home': 60, 'away': 40},
                          ]
                        : [],
                    'home': ready
                        ? {
                            'starters': [
                              {'name': 'Player'},
                            ],
                          }
                        : {},
                    'away': {},
                  },
                ),
              );
            },
          ),
        );
        final container = ProviderContainer(
          overrides: [
            repositoryProvider.overrideWithValue(ApiRepository(dio)),
            detailPollIntervalProvider.overrideWithValue(
              const Duration(milliseconds: 5),
            ),
          ],
        );
        final values = <MatchDetail>[];
        final done = Completer<void>();
        final subscription = container.listen(
          matchDetailProvider('fb_match_test'),
          (previous, next) {
            final value = next.asData?.value;
            if (value != null) {
              values.add(value);
              if (!value.pending && !done.isCompleted) done.complete();
            }
          },
        );
        await done.future.timeout(const Duration(seconds: 2));
        expect(demands, 1);
        expect(requests, arrives ? 3 : 6);
        expect(values.last.pending, false);
        expect(values.last.statistics.isNotEmpty, arrives);
        expect(values.last.homeStarters.isNotEmpty, arrives);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(requests, arrives ? 3 : 6);
        subscription.close();
        container.dispose();
        dio.close();
      },
    );
  }

  testWidgets('calendar controls remain usable on a cold loading date', (
    tester,
  ) async {
    final dates = <DateTime>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          calendarSnapshotProvider.overrideWith((ref, date) {
            dates.add(date);
            return const Stream<Snapshot>.empty();
          }),
          liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
          followsProvider.overrideWith((ref) => Stream.value({})),
          preferenceProvider.overrideWith(
            (ref) => const Stream<CountryPreference>.empty(),
          ),
        ],
        child: const MaterialApp(home: MatchesScreen()),
      ),
    );
    await tester.pump();
    expect(find.text('AYER'), findsOneWidget);
    expect(find.text('HOY'), findsOneWidget);
    expect(find.text('Tu país'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.text('AYER'));
    await tester.pump();
    expect(dates.toSet(), hasLength(2));
    expect(find.byTooltip('Elegir otra fecha'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test('past evidence hides scheduled copy without claiming finished', () {
    final match = Snapshot(payload()).matches.single;
    expect(match.status, 'SCHEDULED');
    expect(match.statusLabel, 'Marcador parcial');
    expect(match.isFinished, false);
    expect(match.showKickoff, false);
    expect(match.score, '2 - 1');
    final eventsOnly = FootballMatch({
      ...match.json,
      'score': null,
      'events': [
        {'type': 'GOAL', 'minute': 20},
      ],
    });
    expect(eventsOnly.statusLabel, isEmpty);
    expect(eventsOnly.score, '—');
    expect(
      FootballMatch({...match.json, 'status': 'VERIFIED'}).statusLabel,
      'Finalizado',
    );
    expect(
      FootballMatch({...match.json, 'status': 'FINISHED_PENDING_VERIFICATION'})
          .statusLabel,
      'Finalizado',
    );
    expect(
      FootballMatch({...match.json, 'status': 'LIVE', 'minute': 63})
          .statusLabel,
      '63′ · En vivo',
    );
  });

  for (final selected in [1, 2]) {
    testWidgets(
      'table changes preserve tab $selected and safely remove active table',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        await tester.runAsync(() async {
          await db.customSelect('select 1').get();
        });
        var hasTable = false;
        var detailStarts = 0;
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            repositoryProvider.overrideWithValue(ApiRepository(Dio())),
            matchContextSnapshotProvider.overrideWith(
              (ref, id) async => Snapshot(payload(table: hasTable)),
            ),
            matchDetailProvider.overrideWith((ref, id) {
              detailStarts++;
              return Stream.value(MatchDetail.empty(id));
            }),
            followsProvider.overrideWith((ref) => Stream.value({})),
            liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
          ],
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: MatchScreen(
                id: 'fb_match_test',
                initialData: Snapshot(payload()),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.text(selected == 1 ? 'Estadísticas' : 'Alineación'),
        );
        await tester.pumpAndSettle();
        hasTable = true;
        container.invalidate(matchContextSnapshotProvider('fb_match_test'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TabBar>(find.byType(TabBar)).controller!.index,
          selected,
        );
        expect(
          tester.widget<TabBar>(find.byType(TabBar)).controller!.length,
          4,
        );
        await tester.tap(find.text('Tabla'));
        await tester.pumpAndSettle();
        hasTable = false;
        container.invalidate(matchContextSnapshotProvider('fb_match_test'));
        await tester.pumpAndSettle();
        expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 2);
        expect(
          tester.widget<TabBar>(find.byType(TabBar)).controller!.length,
          3,
        );
        expect(detailStarts, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        container.dispose();
        await tester.runAsync(db.close);
      },
    );
  }

  testWidgets(
    'missing enrichment ends in empty states, summary stays visible and table is dynamic',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final context = StreamController<Snapshot>();
      await tester.runAsync(() async {
        await db.customSelect('select 1').get();
      });
      // Context future can be refreshed independently of the never-arriving detail.
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          repositoryProvider.overrideWithValue(ApiRepository(Dio())),
          matchContextSnapshotProvider.overrideWith(
            (ref, id) => context.stream.first,
          ),
          matchDetailProvider.overrideWith(
            (ref, id) => Stream.value(MatchDetail.empty(id)),
          ),
          followsProvider.overrideWith((ref) => Stream.value({})),
          liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: MatchScreen(
              id: 'fb_match_test',
              initialData: Snapshot(payload()),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('2 - 1'), findsOneWidget);
      expect(find.text('MARCADOR PARCIAL'), findsOneWidget);
      expect(find.text('PROGRAMADO'), findsNothing);
      expect(find.text('Tabla'), findsNothing);
      await tester.tap(find.text('Estadísticas'));
      await tester.pumpAndSettle();
      expect(find.text('Sin estadísticas'), findsOneWidget);
      await tester.tap(find.text('Alineación'));
      await tester.pumpAndSettle();
      expect(find.text('Sin alineaciones'), findsOneWidget);
      context.add(Snapshot(payload(table: true)));
      await tester.pumpAndSettle();
      expect(find.text('Tabla'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      final data = Snapshot(payload());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [followsProvider.overrideWith((ref) => Stream.value({}))],
          child: MaterialApp(
            home: Scaffold(body: MatchCard(data.matches.single, data)),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('MARCADOR PARCIAL'), findsOneWidget);
      expect(find.text('2 - 1'), findsOneWidget);
      expect(find.text('PROGRAMADO'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await context.close();
        await db.close();
      });
    },
  );
}

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/match_screen.dart';

Json _context(String id, {bool pending = true}) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-11-03T12:00:00Z',
  'coverage': {
    'standingsPending': pending,
    'standings': pending ? 'pending' : 'unavailable',
  },
  'competitions': [
    {'id': 'fb_comp_retarget', 'name': 'Liga sintética'},
  ],
  'teams': [
    {'id': 'fb_team_retarget_h', 'name': 'Local sintético'},
    {'id': 'fb_team_retarget_a', 'name': 'Visitante sintético'},
  ],
  'players': <Json>[],
  'standings': <Json>[],
  'matches': [
    {
      'id': id,
      'competitionId': 'fb_comp_retarget',
      'homeTeamId': 'fb_team_retarget_h',
      'awayTeamId': 'fb_team_retarget_a',
      'startTime': '2026-11-01T18:00:00Z',
      'status': 'VERIFIED',
      'score': {'home': 1, 'away': 0},
      'events': <Json>[],
      'statistics': <Json>[],
    },
  ],
};

void main() {
  for (final scenario in ['spent', 'pending', 'same-id', 'detail-window']) {
    testWidgets(
      'reused MatchScreen keeps recovery scoped to its match: $scenario',
      (tester) async {
        tester.view.physicalSize = const Size(390, 820);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final db = AppDatabase(NativeDatabase.memory());
        await tester.runAsync(() => db.customSelect('select 1').get());
        final reads = <String, int>{};
        final dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                final id = options.queryParameters['id']?.toString() ?? '';
                if (options.path == '/v1/match-context') {
                  reads.update(id, (value) => value + 1, ifAbsent: () => 1);
                  handler.resolve(
                    Response(
                      requestOptions: options,
                      data: _context(id, pending: scenario != 'detail-window'),
                    ),
                  );
                } else if (options.path == '/v1/match-preview') {
                  handler.resolve(
                    Response(
                      requestOptions: options,
                      data: {'schemaVersion': 1, 'matchId': id},
                    ),
                  );
                } else {
                  handler.resolve(
                    Response(
                      requestOptions: options,
                      data: {
                        ...MatchDetail.empty(id).json,
                        if (scenario == 'detail-window' &&
                            id == 'fb_match_retarget_second')
                          'pending': true,
                      },
                    ),
                  );
                }
              },
            ),
          );
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            repositoryProvider.overrideWithValue(ApiRepository(dio)),
            followsProvider.overrideWith((ref) => Stream.value({})),
            liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
          ],
        );
        var closed = false;
        Future<void> close() async {
          if (closed) return;
          closed = true;
          await tester.pumpWidget(const SizedBox());
          container.dispose();
          dio.close(force: true);
          await tester.runAsync(db.close);
        }

        addTearDown(close);

        Future<void> open(String id) async {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                home: MatchScreen(
                  id: id,
                  initialData: Snapshot(
                    _context(id, pending: scenario != 'detail-window'),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
        }

        const first = 'fb_match_retarget_first';
        const second = 'fb_match_retarget_second';
        await open(first);
        final state = tester.state(find.byType(MatchScreen));
        if (scenario == 'spent') {
          for (final delay in [
            ...standingsRetryDelays,
            ...standingsSilentRetryDelays,
          ]) {
            await tester.pump(delay + const Duration(milliseconds: 100));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(reads[first], 6);
        } else {
          await tester.pump(
            Duration(seconds: scenario == 'detail-window' ? 10 : 7),
          );
        }
        await open(scenario == 'same-id' ? first : second);
        expect(tester.state(find.byType(MatchScreen)), same(state));
        if (scenario == 'detail-window') {
          expect(
            find.byKey(const ValueKey('match-refreshing')),
            findsOneWidget,
          );
          await tester.pump(
            matchDetailRefreshIndicatorDuration +
                const Duration(milliseconds: 100),
          );
          expect(find.byKey(const ValueKey('match-refreshing')), findsNothing);
        } else if (scenario == 'same-id') {
          await tester.pump(const Duration(milliseconds: 1500));
          await tester.pump();
          expect(
            reads[first],
            2,
            reason: 'a rebuild of the same match must retain its scheduled recovery',
          );
        } else {
          expect(reads[second], 1);
          if (scenario == 'pending') {
            await tester.pump(const Duration(milliseconds: 1500));
            await tester.pump();
            expect(
              reads[second],
              1,
              reason: 'the previous match\'s timer must not refresh the new match early',
            );
          }
          await tester.pump(
            standingsRetryDelays.first + const Duration(milliseconds: 100),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(
            reads[second],
            2,
            reason:
                'the second match must have its own fresh bounded retry budget',
          );
        }
        expect(tester.takeException(), isNull);
        await close();
      },
    );
  }
}

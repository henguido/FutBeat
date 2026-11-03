import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/theme.dart';
import 'package:futbeat/features/entities/standings.dart';
import 'package:futbeat/features/matches/match_screen.dart';

const _competition = 'fb_comp_full258';

Snapshot _context({bool stale = false}) => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-11-03T12:00:00Z',
  'freshness': {'stale': stale},
  'competitions': [
    {'id': _competition, 'name': 'Liga sintética', 'season': '2027'},
  ],
  'teams': [
    for (var i = 1; i <= 12; i++)
      {'id': 'fb_team_full258_$i', 'name': 'Equipo $i'},
  ],
  'players': <Json>[],
  'matches': <Json>[],
  'standings': [
    for (final season in ['2026', '2027'])
      {
        'competitionId': _competition,
        'season': season,
        'groupsResolved': true,
        'currentGroup': 'Clausura',
        'rows': [
          for (final phase in ['Apertura', 'Clausura'])
            for (var i = 1; i <= 12; i++)
              {
                'teamId': 'fb_team_full258_$i',
                'position': i,
                'group': phase,
                'played': 8,
                'won': 5,
                'drawn': 2,
                'lost': 1,
                'gf': season == '2026' ? 12 : 24,
                'ga': 4,
                'points': 17,
              },
        ],
      },
  ],
});

void main() {
  for (final stale in [false, true]) {
    testWidgets(
      'full table keeps the cached match season and phase (stale=$stale)',
      (tester) async {
        tester.view.physicalSize = const Size(390, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final data = _context(stale: stale);
        var competitionNavigations = 0;
        var requests = 0;
        final dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                requests++;
                handler.reject(
                  DioException(
                    requestOptions: options,
                    type: DioExceptionType.connectionError,
                  ),
                );
              },
            ),
          );
        final container = ProviderContainer(
          overrides: [repositoryProvider.overrideWithValue(ApiRepository(dio))],
        );
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => Scaffold(
                body: ListView(
                  children: [
                    MatchStandingsTab(
                      data,
                      _competition,
                      refreshing: false,
                      homeTeamId: 'fb_team_full258_2',
                      awayTeamId: 'fb_team_full258_5',
                      season: '2026',
                      stage: 'Apertura - Regular season',
                      compactContext: true,
                    ),
                  ],
                ),
              ),
            ),
            GoRoute(
              path: '/competition/:id',
              builder: (_, _) {
                competitionNavigations++;
                // The competition overview chooses its current season when no
                // match context is supplied, as the real competition view does.
                return Scaffold(
                  body: ListView(children: [Standings(data, _competition)]),
                );
              },
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              theme: futbeatTheme(),
              routerConfig: router,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('standings-row-fb_team_full258_12')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('standings-group-Apertura')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('standings-show-full')));
        await tester.pumpAndSettle();
        expect(
          competitionNavigations,
          0,
          reason: 'opening the current competition overview discards the match season/phase',
        );
        expect(find.text('Tabla completa'), findsOneWidget);
        final full = tester.widget<Standings>(find.byType(Standings).last);
        expect(identical(full.data, data), isTrue);
        expect(full.season, '2026');
        expect(full.stage, 'Apertura - Regular season');
        expect(full.contextRows, isNull);
        expect(
          find.byKey(const ValueKey('standings-group-Apertura')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('standings-group-Clausura')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('standings-row-fb_team_full258_12')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('standings-saved')),
          stale ? findsOneWidget : findsNothing,
        );
        expect(requests, 0);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('standings-show-full')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('standings-row-fb_team_full258_12')),
          findsNothing,
        );
        expect(requests, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        container.dispose();
        dio.close(force: true);
      },
    );
  }
}

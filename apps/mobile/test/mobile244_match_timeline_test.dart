import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/theme.dart';
import 'package:futbeat/features/matches/match_screen.dart';
import 'package:go_router/go_router.dart';

// Synthetic canonical IDs and observations. No network/media requests.
const _matchId = 'fb_match_synthetic244';
const _scorer = 'fb_player_synthetic244';
const _homonym = 'fb_player_other244';
Json _row(String id, int number) => {
  'canonicalId': id,
  'name': 'Nombre compartido',
  'number': number,
  'position': 'FWD',
};
Snapshot _snapshot({bool event = false}) => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-10-31T20:00:00Z',
  'teams': [
    {'id': 'fb_team_h244', 'name': 'Local sintético'},
    {'id': 'fb_team_a244', 'name': 'Visitante sintético'},
  ],
  'competitions': [
    {'id': 'fb_comp_244', 'name': 'Competición sintética'},
  ],
  'players': [
    {'id': _scorer, 'name': 'Nombre compartido'},
    {'id': _homonym, 'name': 'Nombre compartido'},
  ],
  'matches': [
    {
      'id': _matchId,
      'competitionId': 'fb_comp_244',
      'homeTeamId': 'fb_team_h244',
      'awayTeamId': 'fb_team_a244',
      'startTime': '2026-10-31T18:00:00Z',
      'status': 'FT',
      'score': {'home': 1, 'away': 0},
      'events': [
        if (event)
          {
            'id': 'fb_event_244',
            'type': 'GOAL',
            'minute': 18,
            'teamId': 'fb_team_h244',
            'canonicalPlayerId': _scorer,
            'score': {'home': 1, 'away': 0},
          },
      ],
    },
  ],
  'standings': [],
});
MatchDetail _detail({List<Json> home = const [], List<Json> away = const []}) =>
    MatchDetail({
      ...MatchDetail.empty(_matchId).json,
      'available': true,
      'home': {'starters': home},
      'away': {'starters': away},
    });

Future<void> _pump(
  WidgetTester tester,
  Snapshot data,
  MatchDetail detail, {
  bool scoped = false,
  double textScale = 1,
}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) {
          Widget timeline = MatchTimeline(data, data.match(_matchId)!, detail);
          if (scoped) {
            timeline = MatchPlayerScope(
              detail: detail,
              home: data.team('fb_team_h244')!,
              away: data.team('fb_team_a244')!,
              child: timeline,
            );
          }
          return Scaffold(body: SingleChildScrollView(child: timeline));
        },
      ),
      GoRoute(
        path: '/player/:id',
        builder: (_, state) =>
            Scaffold(body: Text('profile:${state.pathParameters['id']}')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    MaterialApp.router(
      theme: futbeatTheme(),
      routerConfig: router,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('failed empty timeline is not a verified absence of events', (
    tester,
  ) async {
    await _pump(tester, _snapshot(), _detail().withOfflineUnavailable());
    expect(
      find.text('No se pudo conectar. Eventos no disponibles.'),
      findsOneWidget,
    );
    expect(find.text('Sin eventos'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
  testWidgets('normal empty and pending states remain distinct', (
    tester,
  ) async {
    await _pump(tester, _snapshot(), _detail());
    expect(find.text('Sin eventos'), findsOneWidget);
    await _pump(tester, _snapshot(), MatchDetail.waiting(_matchId));
    expect(find.text('Cargando eventos…'), findsOneWidget);
    expect(find.text('Sin eventos'), findsNothing);
  });
  testWidgets(
    'cached canonical events remain visible after failed detail read',
    (tester) async {
      await _pump(
        tester,
        _snapshot(event: true),
        _detail().withOfflineUnavailable(),
      );
      expect(find.text('Nombre compartido'), findsOneWidget);
      expect(
        find.text('No se pudo conectar. Eventos no disponibles.'),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('timeline-score-1–0')), findsOneWidget);
    },
  );
  testWidgets(
    'timeline opens the canonical local lineup panel, never the homonym',
    (tester) async {
      await _pump(
        tester,
        _snapshot(event: true),
        _detail(home: [_row(_scorer, 9)], away: [_row(_homonym, 14)]),
        scoped: true,
      );
      await tester.tap(find.text('Nombre compartido'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('player-sheet')), findsOneWidget);
      expect(find.text('#9'), findsOneWidget);
      expect(find.text('#14'), findsNothing);
      expect(find.text('profile:$_scorer'), findsNothing);
      expect(
        find.byKey(const ValueKey('player-sheet-profile')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('partial legacy timeline preserves canonical profile fallback', (
    tester,
  ) async {
    await _pump(tester, _snapshot(event: true), _detail(), scoped: true);
    await tester.tap(find.text('Nombre compartido'));
    await tester.pumpAndSettle();
    expect(find.text('profile:$_scorer'), findsOneWidget);
    expect(find.byKey(const ValueKey('player-sheet')), findsNothing);
  });
  testWidgets('ambiguous roster side is never guessed for the local panel', (
    tester,
  ) async {
    await _pump(
      tester,
      _snapshot(event: true),
      _detail(home: [_row(_scorer, 9)], away: [_row(_scorer, 14)]),
      scoped: true,
    );
    await tester.tap(find.text('Nombre compartido'));
    await tester.pumpAndSettle();
    expect(find.text('profile:$_scorer'), findsOneWidget);
    expect(find.byKey(const ValueKey('player-sheet')), findsNothing);
  });
  testWidgets('local timeline player panel stays usable with enlarged text', (
    tester,
  ) async {
    await _pump(
      tester,
      _snapshot(event: true),
      _detail(home: [_row(_scorer, 9)]),
      scoped: true,
      textScale: 1.6,
    );
    await tester.tap(find.text('Nombre compartido'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-sheet-profile')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

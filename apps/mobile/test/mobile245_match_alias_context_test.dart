import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/theme.dart';
import 'package:futbeat/features/matches/match_screen.dart';
import 'package:go_router/go_router.dart';

import 'support/visual_test_fonts.dart';

const _alias = 'fb_player_alias245';
const _canonical = 'fb_player_canonical245';
const _other = 'fb_player_homonym245';
const _match = 'fb_match_alias245';
Json _row(String id, int number) => {
  'canonicalId': id,
  'name': 'Jugador registrado',
  'number': number,
};

Future<int Function()> _open(
  WidgetTester tester, {
  required Map<String, String> redirects,
  Set<String> presentationOnly = const {},
  bool targetExists = true,
  bool ambiguousRoster = false,
  bool presentedTarget = false,
}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final data = Snapshot({
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': '2026-11-01T00:00:00Z',
    'entityRedirects': redirects,
    '_futbeatDisplayRedirectIds': presentationOnly.toList(),
    'teams': [
      {'id': 'fb_team_h245', 'name': 'Local sintético'},
      {'id': 'fb_team_a245', 'name': 'Visitante sintético'},
    ],
    'competitions': [
      {'id': 'fb_comp_alias245', 'name': 'Competición sintética'},
    ],
    'players': [
      {'id': _alias, 'name': 'Jugador registrado'},
      if (targetExists)
        {
          'id': _canonical,
          'name': 'Jugador registrado',
          if (presentedTarget) 'displaySourceAliasId': 'fb_player_display245',
        },
      {'id': _other, 'name': 'Jugador registrado'},
    ],
    'matches': [
      {
        'id': _match,
        'competitionId': 'fb_comp_alias245',
        'homeTeamId': 'fb_team_h245',
        'awayTeamId': 'fb_team_a245',
        'startTime': '2026-10-31T18:00:00Z',
        'status': 'VERIFIED',
        'score': {'home': 1, 'away': 0},
        'events': [
          {
            'id': 'fb_event_alias245',
            'type': 'GOAL',
            'minute': 18,
            'canonicalPlayerId': _alias,
            'teamId': 'fb_team_h245',
          },
        ],
      },
    ],
    'standings': [],
  });
  final detail = MatchDetail({
    ...MatchDetail.empty(_match).json,
    'available': true,
    'home': {
      'starters': [_row(_canonical, 9)],
    },
    'away': {
      'starters': [_row(ambiguousRoster ? _canonical : _other, 12)],
    },
  });
  var profileRoutes = 0;
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(
          body: SingleChildScrollView(
            child: MatchPlayerScope(
              detail: detail,
              home: data.team('fb_team_h245')!,
              away: data.team('fb_team_a245')!,
              child: MatchTimeline(data, data.match(_match)!, detail),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/player/:id',
        builder: (_, state) {
          profileRoutes++;
          return Scaffold(body: Text('profile:${state.pathParameters['id']}'));
        },
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    MaterialApp.router(theme: futbeatTheme(), routerConfig: router),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Jugador registrado'));
  await tester.pumpAndSettle();
  return () => profileRoutes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFutBeatVisualFonts);

  for (final redirects in [
    {_alias: _canonical},
    {_alias: 'fb_player_mid245', 'fb_player_mid245': _canonical},
  ]) {
    testWidgets(
      'explicit ${redirects.length}-edge canonical redirect reuses local roster context',
      (tester) async {
        final profileRoutes = await _open(tester, redirects: redirects);
        expect(find.byKey(const ValueKey('player-sheet')), findsOneWidget);
        expect(find.text('#9'), findsOneWidget);
        expect(find.text('#12'), findsNothing);
        expect(profileRoutes(), 0); // Local panel, no extra profile/API route.
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final presentation in [
    {_alias},
    {'fb_player_mid245'},
  ]) {
    testWidgets(
      'presentation edge $presentation is not canonical identity evidence',
      (tester) async {
        final profileRoutes = await _open(
          tester,
          redirects: {
            _alias: 'fb_player_mid245',
            'fb_player_mid245': _canonical,
          },
          presentationOnly: presentation,
        );
        expect(find.byKey(const ValueKey('player-sheet')), findsNothing);
        expect(find.text('profile:$_alias'), findsOneWidget);
        expect(profileRoutes(), 1);
      },
    );
  }
  testWidgets('an absent canonical target retains alias profile fallback', (
    tester,
  ) async {
    await _open(tester, redirects: {_alias: _canonical}, targetExists: false);
    expect(find.byKey(const ValueKey('player-sheet')), findsNothing);
    expect(find.text('profile:$_alias'), findsOneWidget);
  });
  testWidgets(
    'a synthetic display-only target is not a canonical roster bridge',
    (tester) async {
      await _open(
        tester,
        redirects: {_alias: _canonical},
        presentedTarget: true,
      );
      expect(find.byKey(const ValueKey('player-sheet')), findsNothing);
      expect(find.text('profile:$_alias'), findsOneWidget);
    },
  );
  testWidgets('a redirect cycle retains existing profile fallback', (
    tester,
  ) async {
    await _open(
      tester,
      redirects: {_alias: 'fb_player_mid245', 'fb_player_mid245': _alias},
    );
    expect(find.byKey(const ValueKey('player-sheet')), findsNothing);
    expect(find.text('profile:$_alias'), findsOneWidget);
  });
  testWidgets('an overlong chain cannot infer local player context', (
    tester,
  ) async {
    final redirects = <String, String>{_alias: 'fb_player_mid0'};
    for (var i = 0; i < 9; i++) {
      redirects['fb_player_mid$i'] = i == 8
          ? _canonical
          : 'fb_player_mid${i + 1}';
    }
    await _open(tester, redirects: redirects);
    expect(find.byKey(const ValueKey('player-sheet')), findsNothing);
    expect(find.text('profile:$_alias'), findsOneWidget);
  });
  testWidgets('canonical resolution never guesses an ambiguous roster side', (
    tester,
  ) async {
    await _open(tester, redirects: {_alias: _canonical}, ambiguousRoster: true);
    expect(find.byKey(const ValueKey('player-sheet')), findsNothing);
    expect(find.text('profile:$_canonical'), findsOneWidget);
  });
  testWidgets(
    'shared name without redirect does not merge into roster identity',
    (tester) async {
      await _open(tester, redirects: {});
      expect(find.byKey(const ValueKey('player-sheet')), findsNothing);
      expect(find.text('profile:$_alias'), findsOneWidget);
    },
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/theme.dart';
import 'package:futbeat/features/matches/match_screen.dart';

import 'support/visual_test_fonts.dart';

const _match = 'fb_match_scorer245';
const _home = 'fb_team_scorer245_h';
const _away = 'fb_team_scorer245_a';
const _comp = 'fb_comp_scorer245';

Snapshot _snapshot(Map<String, dynamic> score) => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-11-01T00:00:00Z',
  'teams': [
    {'id': _home, 'name': 'Local'},
    {'id': _away, 'name': 'Visitante'},
  ],
  'players': [
    for (var i = 1; i <= 3; i++)
      {'id': 'fb_player_scorer245_$i', 'name': 'Jugador $i'},
  ],
  'competitions': [
    {'id': _comp, 'name': 'Competición sintética'},
  ],
  'matches': [
    {
      'id': _match,
      'competitionId': _comp,
      'homeTeamId': _home,
      'awayTeamId': _away,
      'startTime': '2026-10-31T18:00:00Z',
      'status': 'VERIFIED',
      'score': score,
      'events': [
        for (var i = 1; i <= 3; i++)
          {
            'id': 'fb_event_scorer245_$i',
            'type': 'GOAL',
            'teamId': _home,
            'canonicalPlayerId': 'fb_player_scorer245_$i',
            'minute': i * 10,
          },
      ],
    },
  ],
  'standings': [],
});

List<ScorerLine> _lines(Map<String, dynamic> score) {
  final data = _snapshot(score);
  return matchScorerSummary(
    data.match(_match)!,
    MatchDetail.empty(_match),
    data,
  ).home;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFutBeatVisualFonts);

  test('integral numeric score caps scorer observations exactly like integer score', () {
    final integer = _lines({'home': 2, 'away': 0});
    final numeric = _lines({'home': 2.0, 'away': 0.0});
    expect(
      numeric.map((line) => line.label),
      integer.map((line) => line.label),
    );
    expect(numeric.map((line) => line.label), [
      'Jugador 1 10′',
      'Jugador 2 20′',
    ]);
  });
  test('known integral zero removes stale scorer observations', () {
    expect(_lines({'home': 0.0, 'away': 0.0}), isEmpty);
  });
  test('known side remains capped when the opposite score is unknown', () {
    expect(_lines({'home': 2.0, 'away': null}), hasLength(2));
    expect(_lines({'home': 2.0}), hasLength(2));
  });
  for (final invalid in <Object?>[
    null,
    '2',
    -1,
    1.5,
    double.nan,
    double.infinity,
  ]) {
    test('unknown goal count $invalid never becomes an invented zero cap', () {
      expect(_lines({'home': invalid, 'away': 0}), hasLength(3));
    });
  }
  testWidgets(
    'real-font header and scorer list agree after an integral numeric correction',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Future<void> paint(Map<String, dynamic> score) async {
        final data = _snapshot(score);
        await tester.pumpWidget(
          MaterialApp(
            theme: futbeatTheme(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: MatchHero(
                  data: data,
                  match: data.match(_match)!,
                  competition: data.competition(_comp)!,
                  detail: MatchDetail.empty(_match),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await paint({'home': 3, 'away': 0});
      expect(find.text('Jugador 3 30′'), findsOneWidget);
      await paint({'home': 2.0, 'away': 0.0});
      expect(find.text('2 - 0'), findsOneWidget);
      expect(find.text('Jugador 1 10′'), findsOneWidget);
      expect(find.text('Jugador 2 20′'), findsOneWidget);
      expect(find.text('Jugador 3 30′'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

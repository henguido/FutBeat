import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/theme.dart';
import 'package:futbeat/features/matches/match_screen.dart';

import 'support/visual_test_fonts.dart';

void main() {
  setUpAll(loadFutBeatVisualFonts);
  for (final scale in [1.0, 1.3]) {
    testWidgets('five-player row retains five incidences at A32 scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      final snapshot = Snapshot({
        'schemaVersion': 1,
        'demo': false,
        'updatedAt': '2026-10-31T00:00:00Z',
        'competitions': [
          {'id': 'fb_comp_density', 'name': 'Competición sintética'},
        ],
        'teams': [
          {'id': 'fb_home', 'name': 'Local'},
          {'id': 'fb_away', 'name': 'Visitante'},
        ],
        'players': <dynamic>[],
        'standings': <dynamic>[],
        'matches': [
          {
            'id': 'fb_match_density',
            'competitionId': 'fb_comp_density',
            'homeTeamId': 'fb_home',
            'awayTeamId': 'fb_away',
            'status': 'VERIFIED',
            'startTime': '2026-10-30T18:00:00Z',
            'score': {'home': 3, 'away': 0},
            'events': <dynamic>[],
          },
        ],
      });
      List<Json> players(String side) => [
        for (var i = 1; i <= 11; i++)
          {
            'id': 'fb_player_${side}_$i',
            'canonicalId': 'fb_player_${side}_$i',
            'name': 'Futbolista de nombre extenso $i',
            'number': i,
            'lineupPosition': i,
          },
      ];
      final detail = MatchDetail({
        'matchId': 'fb_match_density',
        'available': true,
        'home': {
          'formation': '5-4-1',
          'starters': players('home'),
          'substitutes': <dynamic>[],
        },
        'away': {
          'formation': '4-2-3-1',
          'starters': players('away'),
          'substitutes': <dynamic>[],
        },
        'statistics': <dynamic>[],
        'incidents': [
          {
            'type': 'GOAL',
            'playerId': 'fb_player_home_2',
            'side': 'home',
            'minute': 15,
          },
          {
            'type': 'GOAL',
            'playerId': 'fb_player_home_2',
            'side': 'home',
            'minute': 65,
          },
          {
            'type': 'GOAL',
            'playerId': 'fb_player_home_8',
            'assistPlayerId': 'fb_player_home_2',
            'side': 'home',
            'minute': 33,
          },
          {
            'type': 'YELLOW_CARD',
            'playerId': 'fb_player_home_2',
            'side': 'home',
            'minute': 30,
          },
          {
            'type': 'SUB_OUT',
            'outPlayerId': 'fb_player_home_2',
            'side': 'home',
            'minute': 75,
          },
        ],
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: futbeatTheme(),
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(1080 / 2.625, 2400 / 2.625),
              devicePixelRatio: 2.625,
              textScaler: TextScaler.linear(scale),
            ),
            child: Scaffold(
              body: SingleChildScrollView(
                child: Lineups(snapshot, snapshot.matches.single, detail),
              ),
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('lineups-combined-pitch')),
        findsOneWidget,
      );
      expect(find.byTooltip('Gol 15′'), findsOneWidget);
      expect(find.byTooltip('Gol 65′'), findsOneWidget);
      expect(find.byTooltip('Asistencia 33′'), findsOneWidget);
      final home = tester.getRect(
        find.byKey(const ValueKey('lineups-home-half')),
      );
      final away = tester.getRect(
        find.byKey(const ValueKey('lineups-away-half')),
      );
      expect(home.height, away.height);
      final player = tester.getRect(
        find.byKey(const ValueKey('lineup-pitch-home-fb_player_home_2')),
      );
      expect(player.top, greaterThanOrEqualTo(home.top));
      expect(player.bottom, lessThanOrEqualTo(home.bottom));
      expect(tester.takeException(), isNull);
    });
  }
}

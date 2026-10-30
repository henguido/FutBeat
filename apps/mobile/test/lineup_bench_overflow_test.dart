import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/matches/match_screen.dart';

void main() {
  for (final scale in [1.0, 1.3]) {
    testWidgets(
      'A32 compact substitutes keep two-line names, dorsal and events at $scale',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final snapshot = Snapshot({
          'schemaVersion': 1,
          'demo': false,
          'updatedAt': '2026-10-30T20:00:00Z',
          'teams': [
            {'id': 'fb_team_home', 'name': 'Everton'},
            {'id': 'fb_team_away', 'name': 'Newcastle United'},
          ],
          'players': <dynamic>[],
          'competitions': [
            {'id': 'fb_comp_league_cup', 'name': 'League Cup'},
          ],
          'matches': [
            {
              'id': 'fb_match_test',
              'competitionId': 'fb_comp_league_cup',
              'homeTeamId': 'fb_team_home',
              'awayTeamId': 'fb_team_away',
              'startTime': '2026-10-29T20:00:00Z',
              'status': 'VERIFIED',
              'score': {'home': 3, 'away': 1},
              'events': <dynamic>[],
            },
          ],
          'standings': <dynamic>[],
        });
        final detail = MatchDetail({
          'matchId': 'fb_match_test',
          'available': true,
          'home': {
            'formation': '4-2-3-1',
            'starters': <dynamic>[],
            'substitutes': [
              {
                'id': 'fb_player_norgaard',
                'canonicalId': 'fb_player_norgaard',
                'name': 'Christian Nørgaard',
                'number': 23,
              },
              {
                'id': 'fb_player_keane',
                'canonicalId': 'fb_player_keane',
                'name': 'Michael Keane',
                'number': 5,
              },
              {
                'id': 'fb_player_maitland',
                'canonicalId': 'fb_player_maitland',
                'name': 'Ainsley Maitland-Niles',
                'number': 2,
              },
              {
                'id': 'fb_player_toure',
                'canonicalId': 'fb_player_toure',
                'name': 'Bazoumana Touré',
                'number': 17,
              },
            ],
          },
          'away': {'starters': <dynamic>[], 'substitutes': <dynamic>[]},
          'incidents': [
            {
              'type': 'SUBSTITUTION',
              'side': 'home',
              'inPlayerId': 'fb_player_maitland',
              'minute': 67,
            },
            {
              'type': 'YELLOW_CARD',
              'side': 'home',
              'playerId': 'fb_player_maitland',
              'minute': 81,
            },
          ],
          'statistics': <dynamic>[],
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: SingleChildScrollView(
                  child: Lineups(snapshot, snapshot.matches.single, detail),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Ainsley Maitland-Niles'));
        await tester.pumpAndSettle();
        expect(find.text('Ainsley Maitland-Niles'), findsOneWidget);
        expect(find.text('Bazoumana Touré'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

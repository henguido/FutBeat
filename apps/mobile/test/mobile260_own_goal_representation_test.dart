import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/matches/match_screen.dart';

void main() {
  test('explicit own goal retains the same player side as the existing flag representation', () {
    final player = <String, dynamic>{
      'id': 'p260',
      'canonicalId': 'fb_player_260',
    };
    final event = <String, dynamic>{
      'id': 'e260',
      'minute': 32,
      'side': 'home',
      'playerId': 'p260',
      'type': 'OWN_GOAL',
    };
    final flagged = <String, dynamic>{
      ...event,
      'type': 'GOAL',
      'ownGoal': true,
    };
    for (final representation in [flagged, event]) {
      expect(
        lineupEventsForPlayer(player, [
          representation,
        ], 'away').map((event) => event.type),
        ['OWN_GOAL'],
      );
      expect(lineupEventsForPlayer(player, [representation], 'home'), isEmpty);
    }
  });

  test('explicit own goal retains scorer and own-goal marker in header', () {
    final data = Snapshot({
      'schemaVersion': 1,
      'demo': false,
      'updatedAt': '2026-11-03T12:00:00Z',
      'teams': [],
      'players': [],
      'competitions': [],
      'matches': [],
      'standings': [],
    });
    final match = FootballMatch({
      'id': 'fb_match_260',
      'homeTeamId': 'h260',
      'awayTeamId': 'a260',
      'score': {'home': 1, 'away': 0},
      'events': [
        {
          'id': 'e260',
          'type': 'OWN_GOAL',
          'minute': 32,
          'side': 'home',
          'playerName': 'Jugador',
        },
      ],
    });
    expect(
      matchScorerSummary(
        match,
        MatchDetail.empty('fb_match_260'),
        data,
      ).home.map((line) => line.label),
      ['Jugador 32′ (a.g.)'],
    );
  });
}

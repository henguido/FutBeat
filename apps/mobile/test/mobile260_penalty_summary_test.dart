import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/matches/match_screen.dart';

void main() {
  test('canonical penalty scorer remains present in the match header', () {
    final payload = <String, dynamic>{
      'schemaVersion': 1,
      'demo': false,
      'updatedAt': '2026-11-03T12:00:00Z',
      'teams': [],
      'players': [],
      'competitions': [],
      'standings': [],
      'matches': [
        {
          'id': 'fb_match_260',
          'homeTeamId': 'fb_team_h260',
          'awayTeamId': 'fb_team_a260',
          'score': {'home': 1, 'away': 0},
          'events': [
            {
              'id': 'fb_event_260',
              'type': 'PENALTY_GOAL',
              'minute': 28,
              'side': 'home',
              'playerName': 'Jugador verificado',
            },
          ],
        },
      ],
    };
    final data = Snapshot(payload);
    final match = FootballMatch(
      (payload['matches'] as List).single as Map<String, dynamic>,
    );
    final summary = matchScorerSummary(
      match,
      MatchDetail.empty('fb_match_260'),
      data,
    );
    expect(summary.home.map((line) => line.label), [
      'Jugador verificado 28′ (p.)',
    ]);
    expect(summary.away, isEmpty);
  });

  test(
    'canonical penalty goal counts as a goal without rewriting the event',
    () {
      final player = <String, dynamic>{
        'id': 'provider260',
        'canonicalId': 'fb_player_260',
      };
      final events = lineupEventsForPlayer(player, [
        {
          'type': 'PENALTY_GOAL',
          'minute': 28,
          'side': 'home',
          'canonicalPlayerId': 'fb_player_260',
        },
        {
          'type': 'MISSED_PENALTY',
          'minute': 38,
          'side': 'home',
          'canonicalPlayerId': 'fb_player_260',
        },
      ], 'home');
      expect(events.map((event) => event.type), [
        'PENALTY_GOAL',
        'MISSED_PENALTY',
      ]);
      expect(playerMatchSummary(player, events).goals, 1);
      expect(playerMatchSummary(player, events).ownGoals, 0);
    },
  );
}

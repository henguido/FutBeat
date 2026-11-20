import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/entities/player_profile.dart';

Snapshot _data({bool assist = false, bool conflict = false}) => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-11-03T12:00:00Z',
  'competitions': [
    {'id': 'fb_comp260', 'name': 'Liga'},
  ],
  'teams': [
    {'id': 'fb_club260', 'name': 'Club'},
    {'id': 'fb_rival260', 'name': 'Rival'},
    {'id': 'fb_selection260', 'name': 'Selección'},
  ],
  'players': [
    {'id': 'fb_player260', 'name': 'Homónimo', 'teamId': 'fb_selection260'},
    {'id': 'fb_other260', 'name': 'Homónimo'},
  ],
  'entityRedirects': {'fb_alias260': 'fb_player260'},
  'standings': [],
  'matches': [
    {
      'id': 'fb_match260',
      'competitionId': 'fb_comp260',
      'homeTeamId': 'fb_club260',
      'awayTeamId': 'fb_rival260',
      'startTime': '2026-11-01T12:00:00Z',
      'status': 'FT',
      'score': {'home': 1, 'away': 0},
      'events': [
        {
          'id': 'fb_event260',
          'type': 'GOAL',
          'minute': 25,
          if (assist)
            'canonicalAssistPlayerId': 'fb_alias260'
          else
            'canonicalPlayerId': conflict ? 'fb_other260' : 'fb_alias260',
          if (conflict) 'playerId': 'fb_player260',
        },
      ],
    },
  ],
});

void main() {
  for (final assist in [false, true]) {
    test(
      'canonical ${assist ? 'assist' : 'goal'} retains prior club fixture and activity',
      () {
        final data = _data(assist: assist);
        expect(
          playerProfileMatches(
            data,
            data.player('fb_player260')!,
          ).map((match) => match.id),
          ['fb_match260'],
        );
        final activity = playerRecentEvents(data, 'fb_player260');
        expect(activity, hasLength(1));
        expect(activity.single.$3, assist);
        expect(playerRecentEvents(data, 'fb_other260'), isEmpty);
      },
    );
  }
  test(
    'conflicting canonical event never attaches by colliding provider field',
    () {
      final data = _data(conflict: true);
      expect(playerProfileMatches(data, data.player('fb_player260')!), isEmpty);
      expect(playerRecentEvents(data, 'fb_player260'), isEmpty);
    },
  );
}

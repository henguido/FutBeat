import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/entities/player_profile.dart';

void main() {
  test('recent player activity orders added minutes newest first without inventing missing minutes', () {
    final data = Snapshot({
      'schemaVersion': 1,
      'demo': false,
      'updatedAt': '2026-11-03T12:00:00Z',
      'teams': [
        {'id': 'fb_home261', 'name': 'Local'},
        {'id': 'fb_away261', 'name': 'Visita'},
      ],
      'competitions': [
        {'id': 'fb_comp261', 'name': 'Liga'},
      ],
      'players': [
        {'id': 'fb_player261', 'name': 'Jugador'},
      ],
      'standings': [],
      'matches': [
        {
          'id': 'fb_match261',
          'competitionId': 'fb_comp261',
          'homeTeamId': 'fb_home261',
          'awayTeamId': 'fb_away261',
          'startTime': '2026-11-02T12:00:00Z',
          'status': 'VERIFIED',
          'events': [
            {
              'id': 'fb_event261_unknown',
              'type': 'YELLOW_CARD',
              'playerId': 'fb_player261',
            },
            for (final extra in [0, 2, 5])
              {
                'id': 'fb_event261_$extra',
                'type': 'GOAL',
                'minute': 90,
                'extraMinute': extra,
                'playerId': 'fb_player261',
              },
          ],
        },
      ],
    });
    expect(
      playerRecentEvents(data, 'fb_player261').map((entry) => entry.$2['id']),
      [
        'fb_event261_5',
        'fb_event261_2',
        'fb_event261_0',
        'fb_event261_unknown',
      ],
    );
  });
}

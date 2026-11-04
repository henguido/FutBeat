import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/matches/match_screen.dart';

void main() {
  test(
    'blank provider substitution IDs cannot match canonical-only starter',
    () {
      final player = <String, dynamic>{'canonicalId': 'fb_player_260'};
      final detail = MatchDetail({
        'home': {
          'starters': [player],
        },
        'incidents': [
          {
            'type': 'SUBSTITUTION',
            'minute': 20,
            'side': 'home',
            'inPlayerId': '',
            'outPlayerId': '',
          },
          {
            'type': 'RED_CARD',
            'minute': 64,
            'side': 'home',
            'canonicalPlayerId': 'fb_player_260',
          },
        ],
      });
      expect(playerMinutesPlayed(player, detail, 'home'), 64);
      final ambiguous = MatchDetail({
        ...detail.json,
        'home': {
          'starters': [player],
          'substitutes': [player],
        },
      });
      expect(playerMinutesPlayed(player, ambiguous, 'home'), isNull);
    },
  );

  for (final type in ['RED_CARD', 'SECOND_YELLOW_CARD', 'YELLOW_RED_CARD']) {
    test(
      'explicit canonical $type anchors starter minutes without provider ID',
      () {
        final player = <String, dynamic>{'canonicalId': 'fb_player_260'};
        final detail = MatchDetail({
          'matchId': 'fb_match_260',
          'home': {
            'starters': [player],
          },
          'incidents': [
            {
              'type': type,
              'minute': 64,
              'side': 'home',
              'canonicalPlayerId': 'fb_player_260',
            },
          ],
        });
        expect(playerMinutesPlayed(player, detail, 'home'), 64);
        expect(playerMinutesPlayed(player, detail, 'away'), isNull);
      },
    );
  }
  test('conflicting canonical dismissal cannot use colliding provider ID', () {
    final player = <String, dynamic>{'id': '7', 'canonicalId': 'fb_player_260'};
    final detail = MatchDetail({
      'home': {
        'starters': [player],
      },
      'incidents': [
        {
          'type': 'RED_CARD',
          'minute': 64,
          'side': 'home',
          'playerId': '7',
          'canonicalPlayerId': 'fb_player_other260',
        },
      ],
    });
    expect(playerMinutesPlayed(player, detail, 'home'), isNull);
  });
}

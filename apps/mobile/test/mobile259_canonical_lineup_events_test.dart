import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/features/matches/match_screen.dart';

void main() {
  test(
    'conflicting canonical identity never falls back to a provider collision',
    () {
      final player = <String, dynamic>{
        'id': '19',
        'canonicalId': 'fb_player_259',
      };
      final incident = <String, dynamic>{
        'type': 'GOAL',
        'minute': 19,
        'side': 'home',
        'playerId': '19',
        'canonicalPlayerId': 'fb_player_other259',
      };
      expect(lineupEventsForPlayer(player, [incident], 'home'), isEmpty);
      expect(
        lineupEventsForPlayer(
          {'id': 'fb_player_other259'},
          [
            <String, dynamic>{...incident, 'playerId': 'different-provider'},
          ],
          'home',
        ),
        isEmpty,
      );
    },
  );

  test(
    'canonical-only roster retains canonical goal and assist in player panel',
    () {
      final incidents = <Map<String, dynamic>>[
        {
          'type': 'GOAL',
          'minute': 19,
          'side': 'home',
          'canonicalPlayerId': 'fb_player_259',
          'canonicalAssistPlayerId': 'fb_player_assist259',
        },
        {
          'type': 'YELLOW_CARD',
          'minute': 39,
          'side': 'home',
          'canonicalPlayerId': 'fb_player_259',
        },
      ];
      final scorer = <String, dynamic>{
        'canonicalId': 'fb_player_259',
        'name': 'Homónimo',
      };
      final assister = <String, dynamic>{
        'canonicalId': 'fb_player_assist259',
        'name': 'Homónimo',
      };
      expect(
        lineupEventsForPlayer(
          scorer,
          incidents,
          'home',
        ).map((event) => event.type),
        ['GOAL', 'YELLOW_CARD'],
      );
      expect(
        lineupEventsForPlayer(
          assister,
          incidents,
          'home',
        ).map((event) => event.type),
        ['ASSIST'],
      );
      expect(
        lineupEventsForPlayer(
          {'canonicalId': 'fb_player_other259', 'name': 'Homónimo'},
          incidents,
          'home',
        ),
        isEmpty,
      );
      expect(lineupEventsForPlayer(scorer, incidents, 'away'), isEmpty);
    },
  );
}

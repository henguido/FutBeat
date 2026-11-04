import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/matches/match_screen.dart';

void main() {
  for (final type in ['SECOND_YELLOW_CARD', 'YELLOW_RED_CARD']) {
    for (final starter in [true, false]) {
      test('$type anchors dismissal minutes and card summary ($starter)', () {
        final player = <String, dynamic>{
          'id': 'provider259',
          'canonicalId': 'fb_player_259',
        };
        final detail = MatchDetail({
          'matchId': 'fb_match_259',
          'home': {
            'starters': starter ? [player] : [],
            'substitutes': starter ? [] : [player],
          },
          'incidents': [
            if (!starter)
              {
                'type': 'SUBSTITUTION',
                'minute': 46,
                'side': 'home',
                'inPlayerId': 'provider259',
              },
            {
              'type': 'YELLOW_CARD',
              'minute': 50,
              'side': 'home',
              'playerId': 'provider259',
            },
            {
              'type': type,
              'minute': 72,
              'side': 'home',
              'playerId': 'provider259',
            },
          ],
        });
        final events = lineupEventsForPlayer(player, detail.incidents, 'home');
        final minutes = playerMinutesPlayed(player, detail, 'home');
        expect(minutes, starter ? 72 : 26);
        final summary = playerMatchSummary(player, events, minutes: minutes);
        expect(summary.yellowCards, 2);
        expect(summary.redCards, 1);
        expect(events.where((event) => event.type == type), hasLength(1));
        expect(playerMinutesPlayed(player, detail, 'away'), isNull);
      });
    }
  }
}

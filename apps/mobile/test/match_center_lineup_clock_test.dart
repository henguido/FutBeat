import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/features/matches/match_screen.dart';

void main() {
  test(
    'lineup keeps identified events when an incident clock is malformed',
    () {
      final events = lineupEventsForPlayer(
        {'id': 'scorer'},
        [
          {
            'side': 'home',
            'playerId': 'scorer',
            'type': 'GOAL',
            'minute': '45+2',
          },
          {
            'side': 'home',
            'playerId': 'scorer',
            'type': 'YELLOW_CARD',
            'minute': 72,
          },
        ],
        'home',
      );

      expect(events.map((event) => event.type), ['GOAL', 'YELLOW_CARD']);
      expect(events.map((event) => event.minute), [null, 72]);
    },
  );
}

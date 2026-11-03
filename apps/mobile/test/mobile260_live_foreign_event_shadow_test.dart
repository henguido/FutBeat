import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';

void main() {
  for (final provider in ['api_football', null]) {
    for (final foreign in [
      <String, dynamic>{'matchId': 'fb_match_other260'},
      <String, dynamic>{'teamId': 'fb_team_other260'},
    ]) {
      test(
        'rejected incoming event cannot shadow retained $provider event by ID: $foreign',
        () {
          final currentEvent = <String, dynamic>{
            'id': 'fb_event260',
            if (provider != null) 'provider': provider,
            'type': 'YELLOW_CARD',
            'minute': 12,
            'matchId': 'fb_match260',
            'teamId': 'fb_home260',
          };
          final match = <String, dynamic>{
            'id': 'fb_match260',
            'status': 'LIVE',
            'homeTeamId': 'fb_home260',
            'awayTeamId': 'fb_away260',
            'events': [currentEvent],
          };
          final update = LiveMatchUpdate(
            matchId: 'fb_match260',
            provider: 'goal_api',
            externalMatchId: '260',
            status: 'LIVE',
            minute: 20,
            homeScore: 0,
            awayScore: 0,
            revision: 2,
            eventCount: 1,
            changedAt: DateTime.utc(2026, 11, 3, 12),
            hasEventList: true,
            events: [
              {...currentEvent, 'provider': 'goal_api', ...foreign},
            ],
          );
          expect(update.applyTo(match)['events'], [currentEvent]);
        },
      );
    }
  }
}

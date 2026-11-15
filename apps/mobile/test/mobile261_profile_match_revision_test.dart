import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/entities/player_profile.dart';

void main() {
  for (final oldStatus in ['VERIFIED', 'LIVE']) {
    test(
      'player profile does not resurrect a corrected goal from another row of the same match: $oldStatus',
      () {
        final base = <String, dynamic>{
          'id': 'fb_match261',
          'competitionId': 'fb_comp261',
          'homeTeamId': 'fb_home261',
          'awayTeamId': 'fb_away261',
          'startTime': '2026-11-02T12:00:00Z',
        };
        final old = <String, dynamic>{
          ...base,
          'status': oldStatus,
          'score': {'home': 1, 'away': 0},
          'events': [
            {
              'id': 'fb_goal261',
              'type': 'GOAL',
              'minute': 25,
              'playerId': 'fb_player261',
            },
          ],
        };
        final corrected = <String, dynamic>{
          ...base,
          'status': 'VERIFIED',
          'score': {'home': 0, 'away': 0},
          'events': [],
        };
        final payload = <String, dynamic>{
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
            {'id': 'fb_player261', 'name': 'Jugador', 'teamId': 'fb_home261'},
          ],
          'standings': [],
          'matches': oldStatus == 'VERIFIED'
              ? [old, corrected]
              : [corrected, old],
        };
        final data = Snapshot(payload);
        final matches = playerProfileMatches(
          data,
          data.player('fb_player261')!,
        );
        expect(matches, hasLength(1));
        expect(matches.single.status, 'VERIFIED');
        expect(matches.single.score, '0 - 0');
        expect(playerRecentEvents(data, 'fb_player261'), isEmpty);
        final separate = Snapshot({
          ...payload,
          'matches': [
            corrected,
            {...corrected, 'id': 'fb_match_other261'},
          ],
        });
        expect(
          playerProfileMatches(separate, separate.player('fb_player261')!),
          hasLength(2),
          reason: 'Distinct canonical match IDs remain distinct even for matching teams and kickoff',
        );
      },
    );
  }
}

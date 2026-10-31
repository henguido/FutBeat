import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';

// Contract/lifecycle regressions, synthetic: not a live sporting observation.
void main() {
  final kickoff = DateTime.utc(2026, 10, 30, 18);
  Json scheduled() => {
    'id': 'fb_match_229',
    'competitionId': 'fb_comp_229',
    'homeTeamId': 'fb_team_home',
    'awayTeamId': 'fb_team_away',
    'startTime': kickoff.toIso8601String(),
    'status': 'SCHEDULED',
    'events': <Json>[],
    'statistics': <Json>[],
  };
  LiveMatchUpdate update(
    String status,
    int revision, {
    int home = 0,
    List<Json> events = const [],
  }) => LiveMatchUpdate(
    matchId: 'fb_match_229',
    provider: 'goal_api',
    externalMatchId: '229',
    status: status,
    minute: revision * 10,
    homeScore: home,
    awayScore: 0,
    revision: revision,
    eventCount: events.length,
    changedAt: kickoff.add(Duration(minutes: revision * 10)),
    receivedAt: kickoff.add(Duration(minutes: revision * 10)),
    events: events,
    hasEventList: true,
  );
  test('scheduled to LIVE, halftime, second half, AET/PEN and terminal', () {
    for (final extra in ['EXTRA_TIME', 'PENALTIES']) {
      var match = scheduled();
      var revision = 0;
      for (final status in [
        'LIVE',
        'HALFTIME',
        'LIVE',
        extra,
        'FINISHED_PENDING_VERIFICATION',
      ]) {
        final row = update(status, ++revision, home: 1);
        match = row.applyTo(match, now: row.receivedAt);
        expect(FootballMatch(match).status, status);
        expect(
          FootballMatch(match).isFinished,
          status == 'FINISHED_PENDING_VERIFICATION',
        );
      }
      final stale = update('LIVE', ++revision);
      expect(
        identical(stale.applyTo(match, now: stale.receivedAt), match),
        isTrue,
      );
    }
  });
  test(
    'goal correction replaces provider list and rejects an older revision',
    () {
      final goal = <String, dynamic>{
        'id': 'fb_event_goal_229',
        'matchId': 'fb_match_229',
        'provider': 'goal_api',
        'type': 'GOAL',
        'minute': 10,
        'teamId': 'fb_team_home',
        'playerId': 'fb_player_229',
        'ownGoal': true,
      };
      final scored = update('LIVE', 1, home: 1, events: [goal]);
      final first = scored.applyTo(scheduled(), now: scored.receivedAt);
      expect(FootballMatch(first).events.single['ownGoal'], isTrue);
      final correction = update('LIVE', 2);
      final corrected = correction.applyTo(first, now: correction.receivedAt);
      expect(corrected['score'], {'home': 0, 'away': 0});
      expect(FootballMatch(corrected).events, isEmpty);
      expect(
        identical(
          scored.applyTo(corrected, now: correction.receivedAt),
          corrected,
        ),
        isTrue,
      );
    },
  );
  test(
    'silent LIVE does not reopen the schedule after the freshness window',
    () {
      final row = update('LIVE', 1);
      final canonical = scheduled();
      expect(
        identical(
          row.applyTo(
            canonical,
            now: row.receivedAt!.add(
              LiveMatchUpdate.staleAfter + const Duration(seconds: 1),
            ),
          ),
          canonical,
        ),
        isTrue,
      );
    },
  );
}

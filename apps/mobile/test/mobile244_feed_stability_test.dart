import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/matches/matches_screen.dart';

FootballMatch _match(
  String id, {
  String competition = 'fb_comp_synthetic',
  String home = 'fb_team_home',
  String away = 'fb_team_away',
  String status = 'SCHEDULED',
  int minute = 0,
  Map<String, int>? score,
}) => FootballMatch({
  'id': id,
  'competitionId': competition,
  'homeTeamId': home,
  'awayTeamId': away,
  'startTime': DateTime.utc(2026, 10, 31, 18, minute).toIso8601String(),
  'status': status,
  'score': ?score,
});

void main() {
  test('equal kickoff order is independent of response ordering', () {
    final fixtures = [
      _match('fb_match_c'),
      _match('fb_match_a'),
      _match('fb_match_b'),
      _match('fb_match_earlier', minute: -30),
    ];
    final forward = [...fixtures]..sort(compareFeedKickoffs);
    final reversed = fixtures.reversed.toList()..sort(compareFeedKickoffs);
    expect(forward.map((m) => m.id), [
      'fb_match_earlier',
      'fb_match_a',
      'fb_match_b',
      'fb_match_c',
    ]);
    expect(reversed.map((m) => m.id), forward.map((m) => m.id));
  });

  test(
    'bucketed dedupe preserves evidence, real second matches and position',
    () {
      final ghost = _match('fb_match_ghost');
      final unrelated = _match('fb_match_other', home: 'fb_team_other');
      final finalResult = _match(
        'fb_match_final',
        status: 'VERIFIED',
        score: {'home': 2, 'away': 1},
      );
      final correctedSameId = _match(
        'fb_match_final',
        status: 'VERIFIED',
        score: {'home': 3, 'away': 1},
      );
      final anotherPlayed = _match(
        'fb_match_second',
        status: 'VERIFIED',
        score: {'home': 0, 'away': 0},
      );
      final otherCompetition = _match(
        'fb_match_cup',
        competition: 'fb_comp_cup',
      );
      final kept = dedupeFixtures([
        ghost,
        unrelated,
        finalResult,
        otherCompetition,
        correctedSameId,
        anotherPlayed,
      ]);
      expect(kept.map((m) => m.id), [
        'fb_match_final',
        'fb_match_other',
        'fb_match_cup',
        'fb_match_second',
      ]);
      expect(kept.first.score, '3 - 1');
    },
  );

  test('large unrelated canonical catalogue retains all fixtures and removes twins', () {
    final fixtures = <FootballMatch>[];
    for (var i = 0; i < 3000; i++) {
      fixtures.add(
        _match('fb_match_$i', home: 'fb_team_h$i', away: 'fb_team_a$i'),
      );
      if (i % 10 == 0) {
        fixtures.add(
          _match(
            'fb_match_final_$i',
            home: 'fb_team_h$i',
            away: 'fb_team_a$i',
            status: 'VERIFIED',
            score: {'home': 1, 'away': 0},
          ),
        );
      }
    }
    final timer = Stopwatch()..start();
    final kept = dedupeFixtures(fixtures);
    timer.stop();
    expect(kept, hasLength(3000));
    expect(kept.map((m) => m.id).toSet(), hasLength(3000));
    for (var i = 0; i < 3000; i++) {
      expect(kept[i].id, i % 10 == 0 ? 'fb_match_final_$i' : 'fb_match_$i');
    }
    // Host diagnostic only; no flaky wall-clock pass threshold.
    debugPrint(
      'MOBILE244_FEED input=${fixtures.length} kept=${kept.length} dedupeMicros=${timer.elapsedMicroseconds}',
    );
  });
}

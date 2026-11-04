import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/matches/matches_screen.dart';

void main() {
  test('local feed dedup benchmark with 3300 rows, no timing pass threshold', () {
    final rows = <FootballMatch>[];
    for (var i = 0; i < 3000; i++) {
      Map<String, dynamic> row(String id, String status) => {
        'id': id,
        'competitionId': 'fb_comp_${i % 80}',
        'homeTeamId': 'fb_team_h$i',
        'awayTeamId': 'fb_team_a$i',
        'startTime': '2026-10-31T18:00:00Z',
        'status': status,
        'score': {
          'home': status == 'VERIFIED' ? 1 : null,
          'away': status == 'VERIFIED' ? 0 : null,
        },
      };
      rows.add(FootballMatch(row('fb_match_$i', 'SCHEDULED')));
      if (i % 10 == 0) {
        rows.add(FootballMatch(row('fb_match_final_$i', 'VERIFIED')));
      }
    }
    final timer = Stopwatch()..start();
    final kept = dedupeFixtures(rows);
    timer.stop();
    expect(kept, hasLength(3000));
    debugPrint(
      'SHIFT244_BENCH input=${rows.length} kept=${kept.length} micros=${timer.elapsedMicroseconds}',
    );
  });
}

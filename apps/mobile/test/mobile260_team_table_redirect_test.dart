import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/entities/team_profile.dart';

void main() {
  test('team profile retains table containing an authoritative redirected team row', () {
    final data = Snapshot({
      'schemaVersion': 1,
      'demo': false,
      'updatedAt': '2026-11-03T12:00:00Z',
      'competitions': [
        {'id': 'fb_comp260', 'name': 'Liga', 'season': '2026'},
      ],
      'teams': [
        {'id': 'fb_team260', 'name': 'Club', 'competitionId': 'fb_comp260'},
        {'id': 'fb_rival260', 'name': 'Rival'},
      ],
      'players': [],
      'matches': [],
      'entityRedirects': {'fb_oldteam260': 'fb_team260'},
      'standings': [
        {
          'competitionId': 'fb_comp260',
          'season': '2026',
          'rows': [
            {'teamId': 'fb_oldteam260', 'position': 1, 'points': 20},
            {'teamId': 'fb_rival260', 'position': 2, 'points': 18},
          ],
        },
      ],
    });
    expect(
      teamTableCompetitionId(data, data.team('fb_team260')!),
      'fb_comp260',
    );
  });
}

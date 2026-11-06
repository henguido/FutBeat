import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/entities/team_profile.dart';

void main() {
  test('explicit redirected primary competition disambiguates two valid team tables', () {
    final data = Snapshot({
      'schemaVersion': 1,
      'demo': false,
      'updatedAt': '2026-11-03T12:00:00Z',
      'competitions': [
        for (final id in ['fb_league260', 'fb_cup260'])
          {'id': id, 'name': 'Competición', 'season': '2026'},
      ],
      'teams': [
        {
          'id': 'fb_team260',
          'name': 'Club',
          'competitionId': 'fb_oldleague260',
        },
        {'id': 'fb_rival260', 'name': 'Rival'},
      ],
      'players': [],
      'matches': [],
      'entityRedirects': {'fb_oldleague260': 'fb_league260'},
      'standings': [
        for (final id in ['fb_league260', 'fb_cup260'])
          {
            'competitionId': id,
            'season': '2026',
            'rows': [
              {'teamId': 'fb_team260', 'position': 1},
              {'teamId': 'fb_rival260', 'position': 2},
            ],
          },
      ],
    });
    expect(
      teamTableCompetitionId(data, data.team('fb_team260')!),
      'fb_league260',
    );
    expect(
      teamTableCompetitionId(
        data,
        Entity({'id': 'fb_team260', 'name': 'Club'}),
      ),
      isNull,
    );
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/entities/standings.dart';

// One provider stage ("League A") holding several groups, split by the
// server from real fixtures into `subgroup`s (20261005030000). The app shows
// only the match's own group and never merges groups. Synthetic data only.

const _comp = 'fb_comp_sg';
final _teams = [for (var i = 1; i <= 8; i++) 'fb_team_sg$i'];

Map<String, dynamic> _row(String team, int position, int? subgroup) => {
  'teamId': team,
  'position': position,
  'group': 'League A',
  'subgroup': ?subgroup,
  'played': 2,
  'won': 1,
  'drawn': 0,
  'lost': 1,
  'gf': 3,
  'ga': 3,
  'points': 9 - position,
};

Snapshot _snapshot({required bool split, bool sameNames = false}) => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-10-05T12:00:00Z',
  'competitions': [
    {'id': _comp, 'name': 'Nations', 'season': '2026'},
  ],
  'teams': [
    for (final id in _teams)
      {'id': id, 'name': sameNames ? 'Atlético' : 'Equipo $id'},
  ],
  'players': <dynamic>[],
  'matches': <dynamic>[],
  'standings': [
    {
      'competitionId': _comp,
      'season': '2026',
      'grouped': false,
      'groupsResolved': split,
      'rows': [
        for (var i = 0; i < 4; i++) _row(_teams[i], i + 1, split ? 1 : null),
        for (var i = 4; i < 8; i++) _row(_teams[i], i - 3, split ? 2 : null),
      ],
    },
  ],
});

void main() {
  test('Match Center shows only the sub-group of both teams', () {
    final data = _snapshot(split: true);
    final groups = standingsGroups(
      standingsTableFor(data, _comp),
      data,
      focusTeamIds: {_teams[5], _teams[6]},
    )!;
    expect(groups, hasLength(1));
    expect(groups.single.label, 'League A · Subgrupo 2');
    expect(groups.single.rows.map((r) => r['teamId']), _teams.sublist(4));
  });

  test('homonymous teams are selected by canonical ID, not display name', () {
    final data = _snapshot(split: true, sameNames: true);
    final groups = standingsGroups(
      standingsTableFor(data, _comp),
      data,
      focusTeamIds: {_teams[5], _teams[6]},
    )!;
    expect(groups, hasLength(1));
    expect(groups.single.rows.map((row) => row['teamId']), _teams.sublist(4));
  });

  test('competition view lists each sub-group separately, never merged', () {
    final data = _snapshot(split: true);
    final groups = standingsGroups(standingsTableFor(data, _comp), data)!;
    expect(groups, hasLength(2));
    for (final group in groups) {
      final positions = group.rows.map((r) => r['position']).toList();
      expect(positions, [1, 2, 3, 4]);
    }
  });

  test('teams of two different sub-groups get their own tables', () {
    final data = _snapshot(split: true);
    final groups = standingsGroups(
      standingsTableFor(data, _comp),
      data,
      focusTeamIds: {_teams[0], _teams[4]},
    )!;
    expect(groups, hasLength(2));
  });

  test('without the split the table stays unavailable (fail-closed)', () {
    final data = _snapshot(split: false);
    expect(standingsGroups(standingsTableFor(data, _comp), data), isNull);
  });
}

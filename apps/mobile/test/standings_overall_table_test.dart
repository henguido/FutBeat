import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/entities/standings.dart';
import 'package:futbeat/features/matches/match_screen.dart';

// A league table stored together with labelled stage groups (the provider
// sends the overall table plus e.g. playoff groups): rows of the overall
// table carry no group, so the stored table is grouped=true and
// groupsResolved=true. Match Center showed "Tabla no disponible" because
// both sides sat in two groups. Synthetic ids and names only.

const _comp = 'fb_comp_ot';

Map<String, dynamic> _row(String team, int position, {String? group}) => {
  'teamId': team,
  'position': position,
  'group': ?group,
  'played': 5,
  'won': 3,
  'drawn': 1,
  'lost': 1,
  'gf': 9,
  'ga': 4,
  'points': 30 - position,
};

final _teams = [for (var i = 1; i <= 20; i++) 'fb_team_ot$i'];

Snapshot _snapshot({
  Map<String, String> redirects = const {},
  List<String>? overallIds,
  List<Map<String, dynamic>> stageRows = const [],
}) => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-09-30T12:00:00Z',
  'entityRedirects': redirects,
  'competitions': [
    {'id': _comp, 'name': 'Liga Sintética', 'season': '2026'},
  ],
  'teams': [
    for (final id in _teams) {'id': id, 'name': 'Equipo $id'},
  ],
  'players': <dynamic>[],
  'matches': <dynamic>[],
  'standings': [
    {
      'competitionId': _comp,
      'season': '2026',
      'grouped': stageRows.isNotEmpty,
      'groupsResolved': true,
      'rows': [
        for (final (i, id) in (overallIds ?? _teams).indexed) _row(id, i + 1),
        ...stageRows,
      ],
    },
  ],
});

final _stages = [
  for (var i = 0; i < 4; i++) _row(_teams[i], i + 1, group: 'Grupo A'),
  for (var i = 4; i < 8; i++) _row(_teams[i], i - 3, group: 'Grupo B'),
];

List<String?>? _labels(Snapshot data, Set<String> focus) => standingsGroups(
  standingsTableFor(data, _comp),
  data,
  focusTeamIds: focus,
)?.map((group) => group.label).toList();

void main() {
  test('overall table plus stage groups: the overall table, never hidden', () {
    final data = _snapshot(stageRows: _stages);
    // Both sides in the overall table and in Grupo A.
    expect(_labels(data, {_teams[0], _teams[1]}), [null]);
    final rows = standingsGroups(
      standingsTableFor(data, _comp),
      data,
      focusTeamIds: {_teams[0], _teams[1]},
    )!.single.rows;
    expect(rows, hasLength(20));
    // Only the overall table holds both: unchanged rule.
    expect(_labels(data, {_teams[0], _teams[10]}), [null]);
    // A team profile (one focus team): the overall table too.
    expect(_labels(data, {_teams[5]}), [null]);
  });

  test('two labelled groups holding both sides still fail closed', () {
    final data = _snapshot(
      overallIds: const [],
      stageRows: [
        ..._stages,
        _row(_teams[0], 1, group: 'Mejores terceros'),
        _row(_teams[1], 2, group: 'Mejores terceros'),
      ],
    );
    expect(_labels(data, {_teams[0], _teams[1]}), isNull);
  });

  test('a row stored under an alias id resolves to its canonical team', () {
    final data = _snapshot(
      redirects: {'fb_team_ot_old': _teams[2]},
      overallIds: [..._teams.take(2), 'fb_team_ot_old', ..._teams.skip(3)],
    );
    expect(standingsTeam(data, 'fb_team_ot_old')?.id, _teams[2]);
    expect(_labels(data, {_teams[0], _teams[1]}), [null]);
    // Still never a placeholder: an unknown team hides the table.
    final unknown = _snapshot(
      overallIds: [..._teams.take(19), 'fb_team_ot_unknown'],
    );
    expect(_labels(unknown, {_teams[0]}), isNull);
  });

  testWidgets('Match Center Tabla shows the 20-team overall table', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MatchStandingsTab(
              _snapshot(stageRows: _stages),
              _comp,
              refreshing: false,
              homeTeamId: _teams[0],
              awayTeamId: _teams[1],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Tabla no disponible'), findsNothing);
    expect(find.text('Equipo ${_teams[19]}'), findsOneWidget);
    expect(find.byKey(const ValueKey('standings-group-Grupo A')), findsNothing);
  });
}

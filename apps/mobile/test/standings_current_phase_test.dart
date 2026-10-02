import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/entities/standings.dart';
import 'package:futbeat/features/matches/match_screen.dart';

// A league stored with its annual table (rows without `group`) plus one
// labelled table per season phase, the same 20 teams in all three (shape
// seen in production: 20 unlabelled rows ~35 played, 20 "Apertura" 19
// played, 20 "Clausura" in progress). The current phase must be shown,
// never the annual table silently and never a mix. Synthetic ids and names.

const _comp = 'fb_comp_cp';
final _teams = [for (var i = 1; i <= 20; i++) 'fb_team_cp$i'];

Map<String, dynamic> _row(
  String team,
  int position,
  int played, {
  String? group,
}) => {
  'teamId': team,
  'position': position,
  'group': ?group,
  'played': played,
  'won': 0,
  'drawn': played,
  'lost': 0,
  'gf': 0,
  'ga': 0,
  'points': played,
};

Snapshot _snapshot({
  String? currentGroup,
  List<String?> groups = const [null, 'Apertura', 'Clausura'],
  int clausuraTeams = 20,
}) {
  const played = {null: 35, 'Apertura': 19, 'Clausura': 3};
  return Snapshot({
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': '2026-10-01T12:00:00Z',
    'competitions': [
      {'id': _comp, 'name': 'Liga Fases', 'season': '2026'},
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
        'grouped': true,
        'groupsResolved': true,
        'currentGroup': ?currentGroup,
        'rows': [
          for (final group in groups)
            for (final (i, id) in _teams.indexed)
              if (group != 'Clausura' || i < clausuraTeams)
                _row(id, i + 1, played[group] ?? 5, group: group),
        ],
      },
    ],
  });
}

List<String?>? _labels(Snapshot data, Set<String> focus, {String? stage}) =>
    standingsGroups(
      standingsTableFor(data, _comp),
      data,
      focusTeamIds: focus,
      stage: stage,
    )?.map((group) => group.label).toList();

final _match = {_teams[0], _teams[1]};

void main() {
  test('stage tokens: case and accents folded, split on punctuation', () {
    expect(standingsLabelTokens('Primera A - CLÁUSURA'), {
      'primera',
      'a',
      'clausura',
    });
    expect(standingsLabelTokens(null), isEmpty);
    expect(standingsLabelTokens(' - '), isEmpty);
  });

  test('Match Center: the match stage picks its phase table', () {
    final data = _snapshot();
    expect(_labels(data, _match, stage: 'Clausura'), ['Clausura']);
    expect(_labels(data, _match, stage: 'CLÁUSURA'), ['Clausura']);
    expect(_labels(data, _match, stage: 'Clausura - Cuadrangulares'), [
      'Clausura',
    ]);
    expect(_labels(data, _match, stage: 'apertura'), ['Apertura']);
    final rows = standingsGroups(
      standingsTableFor(data, _comp),
      data,
      focusTeamIds: _match,
      stage: 'Clausura',
    )!.single.rows;
    expect(rows, hasLength(20));
    expect(rows.every((row) => row['group'] == 'Clausura'), isTrue);
  });

  test('server currentGroup picks the phase without a match stage', () {
    final data = _snapshot(currentGroup: 'Clausura');
    // Team profile (one focus team) and Match Center before its detail.
    expect(_labels(data, {_teams[7]}), ['Clausura']);
    expect(_labels(data, _match), ['Clausura']);
    // The match's own stage wins over the table hint.
    expect(_labels(data, _match, stage: 'Apertura'), ['Apertura']);
  });

  test('no reliable signal: the annual table, labelled "Tabla general"', () {
    final data = _snapshot();
    expect(_labels(data, _match), [overallStandingsLabel]);
    // A stage that names no group, or several, is not a signal.
    expect(_labels(data, _match, stage: 'Regular season'), [
      overallStandingsLabel,
    ]);
    expect(_labels(data, _match, stage: 'Apertura y Clausura'), [
      overallStandingsLabel,
    ]);
    // A hint that is not one of the groups is ignored.
    expect(_labels(_snapshot(currentGroup: 'Final'), _match), [
      overallStandingsLabel,
    ]);
  });

  test('ambiguous labelled groups without a signal still fail closed', () {
    final data = _snapshot(groups: ['Grupo A', 'Mejores terceros']);
    expect(_labels(data, _match), isNull);
    expect(_labels(data, _match, stage: 'Group Stage'), isNull);
    // With an exact signal the group is known.
    expect(_labels(data, _match, stage: 'Grupo A'), ['Grupo A']);
    expect(
      _labels(
        _snapshot(
          groups: ['Grupo A', 'Mejores terceros'],
          currentGroup: 'Mejores terceros',
        ),
        _match,
      ),
      ['Mejores terceros'],
    );
  });

  test('a stage naming a group that lacks a side is ignored', () {
    // Clausura holds only the first 10 teams.
    final data = _snapshot(clausuraTeams: 10);
    expect(_labels(data, {_teams[0], _teams[15]}, stage: 'Clausura'), [
      overallStandingsLabel,
    ]);
  });

  test('competition view: every group, the annual one labelled', () {
    expect(_labels(_snapshot(), const {}), [
      overallStandingsLabel,
      'Apertura',
      'Clausura',
    ]);
  });

  Future<void> pumpTab(
    WidgetTester tester,
    Snapshot data,
    String? stage,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MatchStandingsTab(
              data,
              _comp,
              refreshing: false,
              homeTeamId: _teams[0],
              awayTeamId: _teams[1],
              stage: stage,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Match Center Tabla shows the current phase table', (
    tester,
  ) async {
    await pumpTab(tester, _snapshot(), 'Clausura');
    expect(find.byKey(const ValueKey('standings-group-Clausura')), findsOne);
    expect(find.byKey(const ValueKey('standings-table-1')), findsNothing);
    // The phase rows (3 played), never the annual table (35 played).
    expect(find.text('35'), findsNothing);
  });

  testWidgets('without a signal the annual table says what it is', (
    tester,
  ) async {
    await pumpTab(tester, _snapshot(), null);
    expect(
      find.byKey(const ValueKey('standings-group-$overallStandingsLabel')),
      findsOne,
    );
    expect(find.text(overallStandingsLabel), findsOne);
    expect(find.text('35'), findsWidgets);
  });

  testWidgets('team profile Tabla follows the server current phase', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Standings(
              _snapshot(currentGroup: 'Clausura'),
              _comp,
              focusTeamIds: {_teams[4]},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('standings-group-Clausura')), findsOne);
    expect(find.text('35'), findsNothing);
  });
}

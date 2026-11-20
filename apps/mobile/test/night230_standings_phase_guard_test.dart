import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/entities/standings.dart';

const _competition = 'fb_comp_phase_guard';
const _home = 'fb_team_home';
const _away = 'fb_team_away';

Snapshot _data({
  bool anotherGroup = false,
  String group = 'Clausura',
}) => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-10-31T04:00:00Z',
  'teams': [
    for (final id in [_home, _away, 'fb_team_other']) {'id': id, 'name': id},
  ],
  'competitions': [
    {'id': _competition, 'name': 'Liga de prueba', 'season': '2026'},
  ],
  'players': <Json>[],
  'matches': <Json>[],
  'standings': [
    {
      'competitionId': _competition,
      'season': '2026',
      'groupsResolved': true,
      // Actual API shape: phase is in group, without a row.stage.
      'rows': [
        for (final (index, id) in [_home, _away].indexed)
          {'teamId': id, 'position': index + 1, 'group': group, 'points': 3},
        if (anotherGroup)
          {'teamId': 'fb_team_other', 'position': 1, 'group': 'Apertura'},
      ],
    },
  ],
});

List<StandingsGroup>? _groups(Snapshot data, String stage) => standingsGroups(
  standingsTableFor(data, _competition, season: '2026'),
  data,
  focusTeamIds: {_home, _away},
  stage: stage,
);

void main() {
  test('a lone group-only Clausura table is not an Apertura table', () {
    expect(_groups(_data(), 'Apertura'), isNull);
  });

  test('the only common group must still match the explicit phase', () {
    expect(_groups(_data(anotherGroup: true), 'Apertura'), isNull);
  });

  test('phase matching folds accents and retains a valid table', () {
    expect(
      _groups(_data(), 'CLÁUSURA - Cuadrangulares')?.single.group,
      'Clausura',
    );
    expect(_groups(_data(group: 'Apertura'), 'Clausura'), isNull);
  });

  test('generic group labels do not become inferred season phases', () {
    expect(
      _groups(_data(group: 'Grupo A'), 'Group Stage')?.single.group,
      'Grupo A',
    );
    expect(_groups(_data(), 'Regular season')?.single.group, 'Clausura');
  });

  testWidgets('wrong group-only phase displays unavailable, not wrong rows', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Standings(
            _data(),
            _competition,
            season: '2026',
            stage: 'Apertura',
            focusTeamIds: const {_home, _away},
          ),
        ),
      ),
    );
    expect(find.text('Tabla no disponible para esta fase.'), findsOneWidget);
    expect(find.byKey(const ValueKey('standings-compact')), findsNothing);
  });
}

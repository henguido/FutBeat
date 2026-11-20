import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/theme.dart';
import 'package:futbeat/features/entities/standings.dart';

import 'support/visual_test_fonts.dart';

const _comp = 'fb_comp_regular245';
const _home = 'fb_team_regular245_h';
const _away = 'fb_team_regular245_a';

Snapshot _data({
  List<String?> groups = const ['Clausura'],
  String genericStage = 'Regular season',
  String? subgroup,
}) => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-10-01T00:00:00Z',
  'competitions': [
    {'id': _comp, 'name': 'Liga sintética', 'season': '2027'},
  ],
  'teams': [
    {'id': _home, 'name': 'Local'},
    {'id': _away, 'name': 'Visitante'},
  ],
  'players': [],
  'matches': [],
  'standings': [
    {
      'competitionId': _comp,
      'season': '2026',
      'currentGroup': 'Apertura',
      'groupsResolved': true,
      'rows': [
        for (final group in groups)
          for (final (index, team) in [_home, _away].indexed)
            {
              'teamId': team,
              'position': index + 1,
              if (group != null) 'stage': genericStage,
              'group': ?group,
              if (group != null && subgroup != null) 'subgroup': subgroup,
              'played': 3,
              'won': 1,
              'drawn': 1,
              'lost': 1,
              'gf': 2,
              'ga': 2,
              'points': 4,
            },
      ],
    },
  ],
});

List<StandingsGroup>? _groups(Snapshot data, String stage) => standingsGroups(
  standingsTableFor(data, _comp, season: '2026'),
  data,
  focusTeamIds: {_home, _away},
  stage: stage,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFutBeatVisualFonts);

  for (final phase in ['Apertura', 'Clausura']) {
    test(
      'an exact $phase request accepts agreeing regular-season phase rows',
      () {
        final data = _data(groups: [phase]).asStale();
        expect(_groups(data, phase)?.single.group, phase);
      },
    );
  }
  test('exact phase selects its own stored block over annual/current-group fallback', () {
    final data = _data(groups: [null, 'Apertura', 'Clausura']).asStale();
    expect(_groups(data, 'Clausura')?.single.group, 'Clausura');
    expect(_groups(data, 'Apertura')?.single.group, 'Apertura');
  });
  test('case accents and punctuation do not change exact phase evidence', () {
    final data = _data(groups: ['CLÁUSURA'], genericStage: 'REGULAR-SEASON');
    expect(_groups(data, 'clausura')?.single.group, 'CLÁUSURA');
  });
  test('opposite phase remains rejected', () {
    expect(_groups(_data(), 'Apertura'), isNull);
    expect(_groups(_data(groups: ['Apertura']), 'Clausura'), isNull);
  });
  test('a generic regular table does not establish a final or playoff', () {
    expect(_groups(_data(), 'Clausura Final'), isNull);
    expect(_groups(_data(), 'Clausura - Cuadrangulares'), isNull);
  });
  test(
    'a stored final or subgroup cannot be collapsed into the phase alone',
    () {
      expect(_groups(_data(groups: ['Clausura Final']), 'Clausura'), isNull);
      expect(
        _groups(_data(genericStage: 'Regular season Final'), 'Clausura'),
        isNull,
      );
      expect(_groups(_data(subgroup: 'Final'), 'Clausura'), isNull);
    },
  );
  test('no phase evidence or several phase tokens stays ambiguous', () {
    expect(_groups(_data(groups: ['Grupo A']), 'Clausura'), isNull);
    expect(
      _groups(_data(groups: ['Apertura', 'Clausura']), 'Regular season'),
      isNull,
    );
    expect(_groups(_data(), 'Apertura y Clausura'), isNull);
  });
  test('wrong regular phase does not win via generic-stage token matching', () {
    final data = _data(groups: [null, 'Clausura']);
    expect(
      _groups(data, 'Apertura - Regular season')?.single.label,
      overallStandingsLabel,
    );
  });
  testWidgets(
    'real-font offline table paints the agreeing phase in its stored season',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: futbeatTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Standings(
                _data().asStale(),
                _comp,
                season: '2026',
                stage: 'Clausura',
                focusTeamIds: const {_home, _away},
                selectableView: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('standings-row-$_home')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('standings-row-$_away')),
        findsOneWidget,
      );
      expect(find.text('Tabla no disponible para esta fase.'), findsNothing);
      expect(find.text('Regular season · Clausura'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

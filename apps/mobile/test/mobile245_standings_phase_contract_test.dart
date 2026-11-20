import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/theme.dart';
import 'package:futbeat/features/entities/standings.dart';

import 'support/visual_test_fonts.dart';

const _competition = 'fb_comp_stored245';
const _home = 'fb_team_stored245_h';
const _away = 'fb_team_stored245_a';

Snapshot _data({
  String tableStage = 'Regular season',
  String tableGroup = 'Clausura',
  bool extraGroup = false,
}) => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-10-01T00:00:00Z',
  'competitions': [
    {
      'id': _competition,
      'name': 'Competición sintética',
      // The stored match/table is historical, not the competition's new season.
      'season': '2027',
    },
  ],
  'teams': [
    {'id': _home, 'name': 'Local sintético'},
    {'id': _away, 'name': 'Visitante sintético'},
    {'id': 'fb_team_stored245_other', 'name': 'Otro equipo sintético'},
  ],
  'players': [],
  'matches': [],
  'standings': [
    {
      'competitionId': _competition,
      'season': '2026',
      'groupsResolved': true,
      'currentGroup': 'Clausura',
      'rows': [
        for (final (index, team) in [_home, _away].indexed)
          {
            'teamId': team,
            'position': index + 1,
            'stage': tableStage,
            'group': tableGroup,
            'played': 1,
            'won': 0,
            'drawn': 1,
            'lost': 0,
            'gf': 0,
            'ga': 0,
            'points': 1,
          },
        if (extraGroup)
          {
            'teamId': 'fb_team_stored245_other',
            'position': 1,
            'stage': 'Regular season',
            'group': 'Apertura',
          },
      ],
    },
  ],
});

List<StandingsGroup>? _groups(Snapshot data, String matchStage) =>
    standingsGroups(
      standingsTableFor(data, _competition, season: '2026'),
      data,
      focusTeamIds: {_home, _away},
      stage: matchStage,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFutBeatVisualFonts);

  test('generic stored stage cannot mask explicit conflicting group phase', () {
    expect(_groups(_data(), 'Apertura - Regular season'), isNull);
  });
  test('only common group still requires a compatible explicit phase', () {
    expect(
      _groups(_data(extraGroup: true), 'Apertura - Regular season'),
      isNull,
    );
  });
  test('matching phase and generic stage preserve historical season rows', () {
    final data = _data(tableGroup: 'Apertura').asStale();
    final table = standingsTableFor(data, _competition, season: '2026');
    expect(table?['season'], '2026');
    expect(
      _groups(data, 'Apertura - Regular season')?.single.group,
      'Apertura',
    );
    expect(standingsTableFor(data, _competition, season: '2027'), isNull);
  });
  test(
    'contradictory phase fields fail closed even if stage alone matches',
    () {
      expect(_groups(_data(tableStage: 'Apertura'), 'Apertura'), isNull);
    },
  );
  test('ambiguous phase evidence is not silently resolved', () {
    expect(
      _groups(
        _data(tableGroup: 'Apertura y Clausura'),
        'Apertura - Regular season',
      ),
      isNull,
    );
  });
  test('generic match stage alone does not invent an Apertura requirement', () {
    expect(_groups(_data(), 'Regular season')?.single.group, 'Clausura');
  });
  test('phase spelling folds case and accents across both fields', () {
    final data = _data(tableGroup: 'CLÁUSURA');
    expect(_groups(data, 'Apertura - Regular season'), isNull);
    expect(
      _groups(data, 'Clausura - Regular season')?.single.group,
      'CLÁUSURA',
    );
  });

  Future<void> pumpStored(WidgetTester tester, Snapshot data) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: futbeatTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Standings(
              data.asStale(),
              _competition,
              season: '2026',
              stage: 'Apertura - Regular season',
              focusTeamIds: const {_home, _away},
              selectableView: false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'offline wrong-phase table cannot paint rows from the wrong group',
    (tester) async {
      await pumpStored(tester, _data());
      expect(find.text('Tabla no disponible para esta fase.'), findsOneWidget);
      expect(find.byKey(const ValueKey('standings-row-$_home')), findsNothing);
      expect(find.byKey(const ValueKey('standings-row-$_away')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'offline matching-phase table still paints its exact stored teams',
    (tester) async {
      await pumpStored(tester, _data(tableGroup: 'Apertura'));
      expect(
        find.byKey(const ValueKey('standings-row-$_home')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('standings-row-$_away')),
        findsOneWidget,
      );
      expect(find.text('Tabla no disponible para esta fase.'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/theme.dart';
import 'package:futbeat/features/entities/standings.dart';

const _competition = 'fb_comp_244standings';
const _first = 'fb_team_244first';
const _second = 'fb_team_244second';
Json _row(String team, {Object? position, String? group}) => {
  'teamId': team,
  if (position != null) 'position': position,
  if (group != null) 'group': group,
  'played': 1,
  'won': 1,
  'drawn': 0,
  'lost': 0,
  'gf': 2,
  'ga': 0,
  'points': 3,
};
Snapshot _snapshot(
  List<Json> rows, {
  Map<String, String> redirects = const {},
}) => Snapshot({
  'schemaVersion': 1, 'demo': false, 'updatedAt': '2026-10-31T20:00:00Z',
  'entityRedirects': redirects,
  'competitions': [
    {'id': _competition, 'name': 'Competición sintética', 'season': '2026'},
  ],
  // Deliberately homonymous; identity comes solely from explicit IDs.
  'teams': [
    {'id': _first, 'name': 'Nombre compartido'},
    {'id': _second, 'name': 'Nombre compartido'},
  ],
  'players': [], 'matches': [],
  'standings': [
    {
      'competitionId': _competition,
      'season': '2026',
      'groupsResolved': true,
      'rows': rows,
    },
  ],
});

void main() {
  test('a canonical team cannot hold two positions in the same group', () {
    final data = _snapshot([
      _row(_first, position: 1),
      _row(_first, position: 2),
    ]);
    expect(standingsGroups(data.standings.single, data), isNull);
  });
  test('explicit redirected rows cannot duplicate the canonical team', () {
    final data = _snapshot(
      [_row(_first, position: 1), _row('fb_team_244alias', position: 2)],
      redirects: {'fb_team_244alias': _first},
    );
    expect(standingsGroups(data.standings.single, data), isNull);
  });
  test('the same team remains legitimate in different published phases', () {
    final data = _snapshot([
      _row(_first, position: 1, group: 'Apertura'),
      _row(_first, position: 1, group: 'Clausura'),
    ]);
    final groups = standingsGroups(data.standings.single, data);
    expect(groups, hasLength(2));
    expect(groups!.map((group) => group.group), ['Apertura', 'Clausura']);
  });
  test('homonymous canonical teams remain separate and valid', () {
    final data = _snapshot([
      _row(_first, position: 1),
      _row(_second, position: 2),
    ]);
    expect(
      standingsGroups(data.standings.single, data)!.single.rows,
      hasLength(2),
    );
  });

  for (final rank in <Object?>[
    null,
    '7',
    1.5,
    0,
    -1,
    double.nan,
    double.infinity,
  ]) {
    testWidgets(
      'unknown or malformed rank $rank never becomes array position',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          final data = _snapshot([_row(_first, position: rank)]).asStale();
          await tester.pumpWidget(
            MaterialApp(
              theme: futbeatTheme(),
              home: Scaffold(
                body: Standings(data, _competition, selectableView: false),
              ),
            ),
          );
          final row = find.byKey(const ValueKey('standings-row-$_first'));
          expect(row, findsOneWidget);
          expect(
            find.descendant(of: row, matching: find.text('—')),
            findsOneWidget,
          );
          expect(
            tester.getSemantics(row).label,
            contains('Posición no disponible'),
          );
          expect(
            tester.getSemantics(row).label,
            isNot(contains('Posición 1,')),
          );
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );
  }
  testWidgets('a real provider position remains visible', (tester) async {
    final data = _snapshot([_row(_first, position: 7)]);
    await tester.pumpWidget(
      MaterialApp(
        theme: futbeatTheme(),
        home: Scaffold(
          body: Standings(data, _competition, selectableView: false),
        ),
      ),
    );
    final row = find.byKey(const ValueKey('standings-row-$_first'));
    expect(find.descendant(of: row, matching: find.text('7')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('—')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

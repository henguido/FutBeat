import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/entities/team_summary.dart';

// #156: team / national-team "Resumen" v2. Synthetic ids and names only.

String _at(Duration offset) =>
    DateTime.now().toUtc().add(offset).toIso8601String();

Map<String, dynamic> _team(String id, String name) => {
  'id': id,
  'name': name,
  'country': 'Nowhere',
};

Map<String, dynamic> _match(
  String id,
  Duration offset, {
  String home = 'fb_team',
  String away = 'fb_rival',
  String status = 'VERIFIED',
  List<int>? score,
  String comp = 'fb_comp_sum',
}) => {
  'id': id,
  'competitionId': comp,
  'homeTeamId': home,
  'awayTeamId': away,
  'startTime': _at(offset),
  'status': status,
  if (score != null) 'score': {'home': score[0], 'away': score[1]},
  'events': <dynamic>[],
  'statistics': <dynamic>[],
};

Map<String, dynamic> _row(String team, int position, {String? group}) => {
  'teamId': team,
  'position': position,
  'group': ?group,
  'played': 6,
  'won': 3,
  'drawn': 1,
  'lost': 2,
  'gf': 9 - position,
  'ga': 5,
  'points': 20 - position,
};

Snapshot _snapshot({
  List<Map<String, dynamic>> matches = const [],
  List<Map<String, dynamic>> standings = const [],
  List<Map<String, dynamic>> news = const [],
}) => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': _at(Duration.zero),
  'competitions': [
    {'id': 'fb_comp_sum', 'name': 'Liga Resumen'},
  ],
  'teams': [
    _team('fb_team', 'Equipo Resumen'),
    _team('fb_rival', 'Rival Resumen'),
    for (var i = 1; i <= 9; i++) _team('fb_t$i', 'Otro $i'),
  ],
  'players': <dynamic>[],
  'standings': standings,
  'matches': matches,
  'news': news,
  'transfers': <dynamic>[],
});

Future<List<String>> _pump(
  WidgetTester tester,
  Snapshot data, {
  String? tableCompetitionId,
}) async {
  tester.view.physicalSize = const Size(390, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final opened = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: TeamSummary(
            data: data,
            team: data.team('fb_team')!,
            matches: [...data.matches]
              ..sort((a, b) => a.startTime.compareTo(b.startTime)),
            competitions: data.competitions,
            players: 0,
            table: tableCompetitionId == null ? null : data,
            tableCompetitionId: tableCompetitionId,
            tableLabel: 'Liga Resumen 2026',
            onOpenTab: opened.add,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return opened;
}

double _y(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text).first).dy;

void main() {
  testWidgets('Partido siguiente comes first: the next match, not a later '
      'one', (tester) async {
    await _pump(
      tester,
      _snapshot(
        matches: [
          _match('fb_m_later', const Duration(days: 9), status: 'SCHEDULED'),
          _match('fb_m_next', const Duration(days: 2), status: 'SCHEDULED'),
          _match('fb_m_old', const Duration(days: -3), score: [2, 0]),
        ],
        news: [
          {
            'id': 'n1',
            'title': 'Nota Resumen',
            'url': 'https://example.test/1',
          },
        ],
      ),
      tableCompetitionId: null,
    );
    expect(find.text('Partido siguiente'), findsOneWidget);
    expect(find.byKey(const ValueKey('team-next-match')), findsOneWidget);
    expect(
      _y(tester, 'Partido siguiente'),
      lessThan(_y(tester, 'Últimos partidos')),
    );
    expect(
      _y(tester, 'Últimos partidos'),
      lessThan(_y(tester, 'Competiciones')),
    );
    expect(find.text('Partidos destacados'), findsNothing);
  });

  testWidgets('a live match is shown as En vivo with its score', (
    tester,
  ) async {
    await _pump(
      tester,
      _snapshot(
        matches: [
          _match(
            'fb_m_live',
            const Duration(minutes: -30),
            status: 'LIVE',
            score: [1, 1],
          ),
        ],
      ),
    );
    expect(find.text('En vivo'), findsOneWidget);
    expect(find.text('Partido siguiente'), findsNothing);
    expect(find.text('1 - 1'), findsOneWidget);
  });

  testWidgets('últimos partidos: the 5 newest finals, from the team side, '
      'without guessing unscored or unfinished ones', (tester) async {
    await _pump(
      tester,
      _snapshot(
        matches: [
          _match('fb_m1', const Duration(days: -1), score: [2, 0]), // G
          _match(
            'fb_m2',
            const Duration(days: -8),
            home: 'fb_rival',
            away: 'fb_team',
            score: [3, 1],
          ), // P
          _match('fb_m3', const Duration(days: -15), score: [1, 1]), // E
          _match(
            'fb_m4',
            const Duration(days: -22),
            home: 'fb_rival',
            away: 'fb_team',
            score: [0, 2],
          ), // G
          _match('fb_m5', const Duration(days: -29), score: [0, 1]), // P
          _match('fb_m6', const Duration(days: -36), score: [5, 0]), // older
          _match('fb_nos', const Duration(days: -4)), // final without score
          _match(
            'fb_wait',
            const Duration(days: -2),
            status: 'SCHEDULED',
          ), // awaiting
        ],
      ),
    );
    final chips = tester
        .widgetList<InkWell>(
          find.descendant(
            of: find.byKey(const ValueKey('team-form')),
            matching: find.byType(InkWell),
          ),
        )
        .map((w) => (w.key! as ValueKey<String>).value)
        .toList();
    expect(chips, [
      'team-form-fb_m1',
      'team-form-fb_m2',
      'team-form-fb_m3',
      'team-form-fb_m4',
      'team-form-fb_m5',
    ]);
    String letter(String id) => tester
        .widget<Text>(
          find
              .descendant(
                of: find.byKey(ValueKey('team-form-$id')),
                matching: find.byType(Text),
              )
              .first,
        )
        .data!;
    expect(['fb_m1', 'fb_m2', 'fb_m3', 'fb_m4', 'fb_m5'].map(letter), [
      'G',
      'P',
      'E',
      'G',
      'P',
    ]);
  });

  testWidgets('table: only the team group, at most 5 rows around the team, '
      'highlighted; Ver todo opens Tabla', (tester) async {
    final opened = await _pump(
      tester,
      _snapshot(
        standings: [
          {
            'competitionId': 'fb_comp_sum',
            'grouped': true,
            'rows': [
              for (var i = 1; i <= 4; i++) _row('fb_t$i', i, group: 'Grupo A'),
              _row('fb_t5', 1, group: 'Grupo B'),
              _row('fb_t6', 2, group: 'Grupo B'),
              _row('fb_t7', 3, group: 'Grupo B'),
              _row('fb_t8', 4, group: 'Grupo B'),
              _row('fb_t9', 5, group: 'Grupo B'),
              _row('fb_team', 6, group: 'Grupo B'),
              _row('fb_rival', 7, group: 'Grupo B'),
            ],
          },
        ],
      ),
      tableCompetitionId: 'fb_comp_sum',
    );
    expect(find.byKey(const ValueKey('team-summary-table')), findsOneWidget);
    expect(find.text('Grupo B'), findsOneWidget);
    expect(find.text('Otro 1'), findsNothing, reason: 'another group');
    final rows = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('team-summary-row-'),
    );
    expect(rows, findsNWidgets(5));
    expect(
      find.byKey(const ValueKey('team-summary-row-fb_team')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('team-summary-row-fb_rival')),
      findsOneWidget,
    );
    expect(find.text('J'), findsOneWidget);
    await tester.tap(find.text('Ver todo').first);
    expect(opened, ['Tabla']);
  });

  testWidgets('an ambiguous table is left out, never shown mixed', (
    tester,
  ) async {
    await _pump(
      tester,
      _snapshot(
        standings: [
          {
            'competitionId': 'fb_comp_sum',
            'groupsResolved': false,
            'rows': [_row('fb_team', 1), _row('fb_rival', 1)],
          },
        ],
      ),
      tableCompetitionId: 'fb_comp_sum',
    );
    expect(find.byKey(const ValueKey('team-summary-table')), findsNothing);
  });

  testWidgets('modules without data are left out (no empty cards)', (
    tester,
  ) async {
    await _pump(tester, _snapshot());
    expect(find.text('Partido siguiente'), findsNothing);
    expect(find.text('Últimos partidos'), findsNothing);
    expect(find.text('Noticias'), findsNothing);
    expect(find.text('Sin partidos próximos'), findsNothing);
    expect(find.byKey(const ValueKey('team-summary-table')), findsNothing);
    // Always-true facts stay.
    expect(find.text('Información'), findsOneWidget);
  });
}

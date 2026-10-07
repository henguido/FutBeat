import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/theme.dart';
import 'package:futbeat/features/entities/standings.dart';
import 'package:futbeat/features/matches/match_screen.dart';
import 'package:go_router/go_router.dart';

const _competition = 'fb_comp_ux2';

Map<String, dynamic> _row(
  String team,
  int position, {
  String? stage,
  String? group,
  String? subgroup,
}) => {
  'teamId': team,
  'position': position,
  'stage': ?stage,
  'group': ?group,
  'subgroup': ?subgroup,
  'played': 8,
  'won': 4,
  'drawn': 2,
  'lost': 2,
  'gf': 12,
  'ga': 8,
  'points': 14,
};

Snapshot _snapshot({
  String? competitionSeason = '2026',
  List<Map<String, dynamic>>? standings,
  String status = 'SCHEDULED',
  Map<String, String> redirects = const {},
  bool longName = false,
}) {
  final teams = [for (var i = 1; i <= 12; i++) 'team_$i'];
  return Snapshot({
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': '2026-10-07T12:00:00Z',
    'entityRedirects': redirects,
    'competitions': [
      {'id': _competition, 'name': 'Liga UX', 'season': ?competitionSeason},
    ],
    'teams': [
      for (final (index, id) in teams.indexed)
        {
          'id': id,
          'name': index == 5 && longName
              ? 'Club Deportivo Extraordinariamente Largo de la Capital'
              : 'Equipo $index',
        },
      for (final alias in redirects.keys) {'id': alias, 'name': 'Alias'},
    ],
    'players': <dynamic>[],
    'matches': [
      {
        'id': 'match',
        'competitionId': _competition,
        'homeTeamId': 'team_2',
        'awayTeamId': 'team_10',
        'startTime': '2099-10-07T18:00:00Z',
        'status': status,
        if (status == 'LIVE') 'score': {'home': 1, 'away': 0},
        'events': <dynamic>[],
        'statistics': <dynamic>[],
      },
    ],
    'standings':
        standings ??
        [
          {
            'competitionId': _competition,
            'season': '2026',
            'groupsResolved': true,
            'rows': [
              for (final (index, id) in teams.indexed) _row(id, index + 1),
            ],
          },
        ],
  });
}

Future<void> _pump(
  WidgetTester tester,
  Snapshot data, {
  double width = 390,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(
          body: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              MatchStandingsTab(
                data,
                _competition,
                refreshing: false,
                homeTeamId: 'team_2',
                awayTeamId: 'team_10',
                season: '2026',
                compactContext: true,
              ),
            ],
          ),
        ),
      ),
      GoRoute(
        path: '/competition/:id',
        builder: (_, state) =>
            Scaffold(body: Text('Competición ${state.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/team/:id',
        builder: (_, state) =>
            Scaffold(body: Text('Equipo ${state.pathParameters['id']}')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
}

Color? _accent(WidgetTester tester, String teamId) {
  final row = tester.widget<Container>(
    find
        .descendant(
          of: find.byKey(ValueKey('standings-row-$teamId')),
          matching: find.byType(Container),
        )
        .first,
  );
  return ((row.decoration! as BoxDecoration).border! as Border).left.color;
}

void main() {
  test('multiple seasons resolve exactly and otherwise fail closed', () {
    final tables = [
      for (final season in ['2025', '2026'])
        {
          'competitionId': _competition,
          'season': season,
          'groupsResolved': true,
          'rows': [_row('team_1', 1)],
        },
    ];
    final current = _snapshot(standings: tables);
    expect(standingsTableFor(current, _competition)?['season'], '2026');
    expect(
      standingsTableFor(current, _competition, season: '2025')?['season'],
      '2025',
    );
    final unknown = _snapshot(competitionSeason: null, standings: tables);
    expect(standingsTableFor(unknown, _competition), isNull);
  });

  test('stage, group and subgroup remain distinct real blocks', () {
    final rows = [
      _row(
        'team_1',
        1,
        stage: 'Fase de grupos',
        group: 'Grupo A',
        subgroup: '1',
      ),
      _row(
        'team_2',
        1,
        stage: 'Fase de grupos',
        group: 'Grupo A',
        subgroup: '2',
      ),
      _row('team_3', 1, stage: 'Ronda de campeonato'),
    ];
    final data = _snapshot(
      standings: [
        {
          'competitionId': _competition,
          'season': '2026',
          'groupsResolved': true,
          'rows': rows,
        },
      ],
    );
    expect(
      standingsGroups(
        standingsTableFor(data, _competition),
        data,
      )?.map((group) => group.label),
      [
        'Fase de grupos · Grupo A · Subgrupo 1',
        'Fase de grupos · Grupo A · Subgrupo 2',
        'Ronda de campeonato',
      ],
    );
  });

  testWidgets('Match Center shows compact context, both accents and CTA', (
    tester,
  ) async {
    await _pump(tester, _snapshot(longName: true), width: 320);

    expect(find.byKey(const ValueKey('standings-compact')), findsOneWidget);
    expect(find.byKey(const ValueKey('standings-view-full')), findsNothing);
    expect(find.byKey(const ValueKey('standings-show-full')), findsOneWidget);
    expect(find.byKey(const ValueKey('standings-row-team_2')), findsOneWidget);
    expect(find.byKey(const ValueKey('standings-row-team_10')), findsOneWidget);
    expect(find.byKey(const ValueKey('standings-row-team_1')), findsOneWidget);
    expect(find.byKey(const ValueKey('standings-row-team_12')), findsNothing);
    expect(_accent(tester, 'team_2'), lime);
    expect(_accent(tester, 'team_10'), awaySideColor);
    expect(find.byKey(const ValueKey('standings-live')), findsNothing);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/standings_match_context.png'),
    );

    await tester.tap(find.byKey(const ValueKey('standings-show-full')));
    await tester.pumpAndSettle();
    expect(find.text('Competición $_competition'), findsOneWidget);
  });

  testWidgets('LIVE indicator requires real in-play status', (tester) async {
    await _pump(tester, _snapshot(status: 'LIVE'));
    expect(find.byKey(const ValueKey('standings-live')), findsNWidgets(2));
  });
}

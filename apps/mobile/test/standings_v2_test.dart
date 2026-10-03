import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/theme.dart';
import 'package:futbeat/features/entities/standings.dart';
import 'package:futbeat/features/matches/match_preview_sections.dart';
import 'package:futbeat/features/matches/match_screen.dart';

// #158 Tabla v2 (Resumida / Completa / Forma) and #147 (never a mixed table
// across groups). Synthetic ids and names only.

const _comp = 'fb_comp_tv2';
const _longName =
    'Club Deportivo Extraordinariamente Largo de la Ciudad Capital';

Map<String, dynamic> _row(
  String team,
  int position, {
  String? group,
  int points = 10,
}) => {
  'teamId': team,
  'position': position,
  'group': ?group,
  'played': 5,
  'won': 3,
  'drawn': 1,
  'lost': 1,
  'gf': 9,
  'ga': 4,
  'points': points,
};

List<String> _teamsOf(String group) => [
  for (var i = 1; i <= 4; i++) 'fb_team_tv2_${group.toLowerCase()}$i',
];

Snapshot _snapshot({
  bool grouped = false,
  bool groupsResolved = true,
  String season = '2026',
  String? tableSeason,
  String? seasonKey,
  String? updatedAt,
  bool? provisional,
  List<Map<String, dynamic>> extraRows = const [],
  Set<String> omittedStandingTeamIds = const {},
  Map<String, String> rowAliases = const {},
  List<Map<String, dynamic>> matches = const [],
}) {
  final teams = grouped
      ? [
          for (final g in ['A', 'B', 'C']) ..._teamsOf(g),
        ]
      : _teamsOf('A');
  String stored(String id) => rowAliases[id] ?? id;
  return Snapshot({
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
    'entityRedirects': {
      for (final MapEntry(:key, :value) in rowAliases.entries) value: key,
    },
    'competitions': [
      {'id': _comp, 'name': 'Liga Tabla Dos', 'season': season},
    ],
    'teams': [
      for (final id in teams)
        {'id': id, 'name': id.endsWith('a1') ? _longName : 'Equipo $id'},
      for (final alias in rowAliases.values)
        {'id': alias, 'name': 'Equipo $alias'},
    ],
    'players': <dynamic>[],
    'matches': matches,
    'standings': [
      {
        'competitionId': _comp,
        'season': tableSeason ?? season,
        'seasonKey': ?seasonKey,
        'updatedAt': ?updatedAt,
        'provisional': ?provisional,
        'grouped': grouped,
        'groupsResolved': groupsResolved,
        'rows': [
          if (grouped)
            for (final g in ['A', 'B', 'C'])
              for (final (i, id) in _teamsOf(g).indexed)
                _row(stored(id), i + 1, group: 'Grupo $g', points: 12 - 3 * i)
          else
            for (final (i, id) in _teamsOf('A').indexed)
              if (!omittedStandingTeamIds.contains(id))
                _row(stored(id), i + 1, points: 12 - 3 * i),
          ...extraRows,
        ],
      },
    ],
  });
}

class _FormServer {
  _FormServer({this.fail = 0});

  /// The first [fail] reads fail (network error).
  int fail;
  int reads = 0;
  Map<String, dynamic>? lastQuery;
  Completer<void>? gate;

  Dio dio() => Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          if (options.path != '/v1/standings-form') {
            handler.reject(
              DioException(requestOptions: options, message: 'unexpected'),
            );
            return;
          }
          reads++;
          lastQuery = options.queryParameters;
          await gate?.future;
          if (fail > 0) {
            fail--;
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
              ),
            );
            return;
          }
          handler.resolve(
            Response(
              requestOptions: options,
              data: {
                'schemaVersion': 1,
                'competitionId': _comp,
                'seasonKey': '2026',
                'teams': {
                  'fb_team_tv2_a1': {
                    'results': ['WIN', 'DRAW', 'LOSS'],
                    'matchIds': ['m1', 'm2', 'm3'],
                  },
                  'fb_team_tv2_a2': {
                    'results': ['LOSS', 'LOSS', 'WIN', 'WIN', 'DRAW'],
                    'matchIds': ['m1', 'm4', 'm5', 'm6', 'm7'],
                  },
                },
                'matchesConsidered': 7,
              },
            ),
          );
        },
      ),
    );
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  FootballRepository? repository,
  double width = 390,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      repositoryProvider.overrideWithValue(repository ?? DemoRepository()),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [child],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Widget _matchTab(Snapshot data, {String? home, String? away}) =>
    MatchStandingsTab(
      data,
      _comp,
      refreshing: false,
      homeTeamId: home,
      awayTeamId: away,
    );

Finder _inTable(String key, Finder matching) =>
    find.descendant(of: find.byKey(ValueKey(key)), matching: matching);

Color? _accent(WidgetTester tester, String teamId) {
  final row = tester.widget<Container>(
    find
        .descendant(
          of: find.byKey(ValueKey('standings-row-$teamId')),
          matching: find.byType(Container),
        )
        .first,
  );
  final border = (row.decoration! as BoxDecoration).border! as Border;
  return border.left.color == Colors.transparent ? null : border.left.color;
}

List<String> _chipLetters(WidgetTester tester, String teamId) => [
  for (final text in tester.widgetList<Text>(
    find.descendant(
      of: find.byKey(ValueKey('standings-form-$teamId')),
      matching: find.byType(Text),
    ),
  ))
    text.data!,
];

void main() {
  testWidgets('three views: Resumida (J header) by default, Completa, Forma', (
    tester,
  ) async {
    final server = _FormServer();
    await _pump(
      tester,
      _matchTab(_snapshot(), home: 'fb_team_tv2_a1', away: 'fb_team_tv2_a3'),
      repository: ApiRepository(server.dio()),
    );
    for (final view in ['compact', 'full', 'form']) {
      expect(find.byKey(ValueKey('standings-view-$view')), findsOneWidget);
    }
    expect(find.text('Resumida'), findsOneWidget);
    expect(find.text('Completa'), findsOneWidget);
    expect(find.text('Forma'), findsOneWidget);
    expect(find.byKey(const ValueKey('standings-compact')), findsOneWidget);
    for (final label in ['Pos', 'Equipo', 'J', 'DG', 'Pts']) {
      expect(_inTable('standings-compact', find.text(label)), findsOneWidget);
    }
    expect(_inTable('standings-compact', find.text('PJ')), findsNothing);
    expect(_inTable('standings-compact', find.text('GF')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('standings-view-full')));
    await _settle(tester);
    for (final label in ['J', 'G', 'E', 'P', 'GF', 'GC', 'DG', 'Pts']) {
      expect(_inTable('standings-full', find.text(label)), findsOneWidget);
    }
    expect(server.reads, 0, reason: 'Forma is loaded only when opened');
    await tester.tap(find.byKey(const ValueKey('standings-view-form')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('standings-form')), findsOneWidget);
    expect(_inTable('standings-form', find.text('Forma')), findsOneWidget);
    expect(_inTable('standings-form', find.text('Pts')), findsOneWidget);
    expect(server.reads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the selected view persists across rebuilds with new data', (
    tester,
  ) async {
    final server = _FormServer();
    final repository = ApiRepository(server.dio());
    await _pump(
      tester,
      _matchTab(_snapshot(), home: 'fb_team_tv2_a1', away: 'fb_team_tv2_a2'),
      repository: repository,
    );
    await tester.tap(find.byKey(const ValueKey('standings-view-full')));
    await _settle(tester);
    // A refresh (new snapshot, "Actualizando tabla…" above) keeps Completa.
    final refreshed = ProviderContainer(
      overrides: [repositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(refreshed.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: refreshed,
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                MatchStandingsTab(
                  _snapshot(),
                  _comp,
                  refreshing: true,
                  homeTeamId: 'fb_team_tv2_a1',
                  awayTeamId: 'fb_team_tv2_a2',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(find.byKey(const ValueKey('standings-updating')), findsOneWidget);
    expect(find.byKey(const ValueKey('standings-full')), findsOneWidget);
    // Forma loaded once, then switching views never reads again.
    await tester.tap(find.byKey(const ValueKey('standings-view-form')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('standings-view-compact')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('standings-view-form')));
    await _settle(tester);
    expect(server.reads, 1);
    expect(find.byKey(const ValueKey('standings-form')), findsOneWidget);
  });

  for (final width in [360.0, 390.0, 430.0]) {
    testWidgets('${width.toInt()} px: every view fits, Resumida and Forma '
        'without horizontal scroll', (tester) async {
      final data = _snapshot(
        matches: [
          {
            'id': 'fb_match_tv2_live',
            'competitionId': _comp,
            'homeTeamId': 'fb_team_tv2_a1',
            'awayTeamId': 'fb_team_tv2_a4',
            'startTime': DateTime.now().toUtc().toIso8601String(),
            'status': 'LIVE',
            'minute': 30,
            'score': {'home': 1, 'away': 0},
            'events': <dynamic>[],
            'statistics': <dynamic>[],
          },
        ],
      );
      await _pump(
        tester,
        _matchTab(data, home: 'fb_team_tv2_a1', away: 'fb_team_tv2_a4'),
        repository: ApiRepository(_FormServer().dio()),
        width: width,
      );
      expect(tester.takeException(), isNull);
      for (final (view, key) in [
        ('compact', 'standings-compact'),
        ('form', 'standings-form'),
      ]) {
        await tester.tap(find.byKey(ValueKey('standings-view-$view')));
        await _settle(tester);
        expect(tester.takeException(), isNull, reason: view);
        final table = find.byKey(ValueKey(key));
        expect(table, findsOneWidget);
        expect(
          find.ancestor(
            of: table,
            matching: find.byWidgetPredicate(
              (w) =>
                  w is SingleChildScrollView &&
                  w.scrollDirection == Axis.horizontal,
            ),
          ),
          findsNothing,
          reason: '$view has no horizontal scroll',
        );
        expect(tester.getRect(table).right, lessThanOrEqualTo(width));
        final name = tester.widget<Text>(
          find.byKey(const ValueKey('standings-name-fb_team_tv2_a1')),
        );
        expect(name.maxLines, 1);
        expect(name.overflow, TextOverflow.ellipsis);
        // LIVE only from the real in-play match.
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('standings-row-fb_team_tv2_a1')),
            matching: find.byKey(const ValueKey('standings-live')),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('standings-row-fb_team_tv2_a2')),
            matching: find.byKey(const ValueKey('standings-live')),
          ),
          findsNothing,
        );
      }
      final switchRect = tester.getRect(
        find.byKey(const ValueKey('standings-view-form')),
      );
      expect(switchRect.right, lessThanOrEqualTo(width));
      await tester.tap(find.byKey(const ValueKey('standings-view-full')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('competition view: every group is its own labelled table', (
    tester,
  ) async {
    await _pump(tester, Standings(_snapshot(grouped: true), _comp));
    for (final g in ['A', 'B', 'C']) {
      expect(find.byKey(ValueKey('standings-group-Grupo $g')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('standings-compact')), findsNWidgets(3));
    expect(find.text('Equipo'), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Match Center: both match teams highlighted, others not', (
    tester,
  ) async {
    await _pump(
      tester,
      _matchTab(
        _snapshot(grouped: true),
        home: 'fb_team_tv2_b1',
        away: 'fb_team_tv2_b3',
      ),
    );
    expect(find.byKey(const ValueKey('standings-group-Grupo B')), findsOne);
    expect(find.byKey(const ValueKey('standings-group-Grupo A')), findsNothing);
    expect(_accent(tester, 'fb_team_tv2_b1'), lime);
    expect(_accent(tester, 'fb_team_tv2_b3'), awaySideColor);
    expect(_accent(tester, 'fb_team_tv2_b2'), isNull);
  });

  testWidgets('#147 cross-group match: the two labelled groups, never mixed', (
    tester,
  ) async {
    await _pump(
      tester,
      _matchTab(
        _snapshot(grouped: true),
        home: 'fb_team_tv2_a1',
        away: 'fb_team_tv2_c2',
      ),
    );
    expect(find.byKey(const ValueKey('standings-group-Grupo A')), findsOne);
    expect(find.byKey(const ValueKey('standings-group-Grupo C')), findsOne);
    expect(find.byKey(const ValueKey('standings-group-Grupo B')), findsNothing);
    expect(find.byKey(const ValueKey('standings-compact')), findsNWidgets(2));
    expect(
      find.byKey(const ValueKey('standings-row-fb_team_tv2_b1')),
      findsNothing,
    );
    expect(_accent(tester, 'fb_team_tv2_a1'), lime);
    expect(_accent(tester, 'fb_team_tv2_c2'), awaySideColor);
    // Each table keeps its own positions (1..4), none merged.
    final groupA = find.byKey(const ValueKey('standings-table-0'));
    final groupC = find.byKey(const ValueKey('standings-table-1'));
    for (final group in [groupA, groupC]) {
      expect(
        find.descendant(
          of: group,
          matching: find.byWidgetPredicate(
            (w) => w is InkWell && '${w.key}'.contains('standings-row-'),
          ),
        ),
        findsNWidgets(4),
      );
    }
    expect(
      find.descendant(
        of: groupA,
        matching: find.byKey(const ValueKey('standings-row-fb_team_tv2_c2')),
      ),
      findsNothing,
    );
  });

  test('group resolution: fail closed when groups cannot be told apart', () {
    final data = _snapshot(grouped: true);
    final table = standingsTableFor(data, _comp);
    expect(
      standingsGroups(
        table,
        data,
        focusTeamIds: {'fb_team_tv2_a1', 'fb_team_tv2_c2'},
      )!.map((g) => g.label),
      ['Grupo A', 'Grupo C'],
    );
    // A focus team missing from every group.
    expect(
      standingsGroups(
        table,
        data,
        focusTeamIds: {'fb_team_tv2_a1', 'fb_team_tv2_zz'},
      ),
      isNull,
    );
    // Cross-group with one unlabelled group: cannot be shown as correct.
    final partial = {
      ...table!,
      'rows': [
        for (final row in (table['rows'] as List).cast<Json>())
          if (row['group'] == 'Grupo C') ({...row}..remove('group')) else row,
      ],
    };
    expect(
      standingsGroups(
        partial,
        data,
        focusTeamIds: {'fb_team_tv2_a1', 'fb_team_tv2_c2'},
      ),
      isNull,
    );
    // Same-group focus keeps working on that partial table.
    expect(
      standingsGroups(
        partial,
        data,
        focusTeamIds: {'fb_team_tv2_a1', 'fb_team_tv2_a2'},
      )!.single.label,
      'Grupo A',
    );
  });

  test('single standings group requires every focus team', () {
    final data = _snapshot();
    final table = standingsTableFor(data, _comp)!;
    final rows = (table['rows'] as List).cast<Json>();
    final bothPresent = {'fb_team_tv2_a1', 'fb_team_tv2_a2'};
    final oneMissing = {
      ...table,
      'rows': [
        for (final row in rows)
          if (row['teamId'] != 'fb_team_tv2_a2') row,
      ],
    };
    final bothMissing = {
      ...table,
      'rows': [
        for (final row in rows)
          if (!bothPresent.contains(row['teamId'])) row,
      ],
    };

    expect(
      standingsGroups(table, data, focusTeamIds: bothPresent)!.single.rows,
      hasLength(4),
    );
    expect(
      standingsGroups(oneMissing, data, focusTeamIds: bothPresent),
      isNull,
    );
    expect(
      standingsGroups(bothMissing, data, focusTeamIds: bothPresent),
      isNull,
    );
    expect(standingsGroups(oneMissing, data)!.single.rows, hasLength(3));
  });

  testWidgets('Match Center hides a partial single-group table', (
    tester,
  ) async {
    await _pump(
      tester,
      _matchTab(
        _snapshot(omittedStandingTeamIds: {'fb_team_tv2_a2'}),
        home: 'fb_team_tv2_a1',
        away: 'fb_team_tv2_a2',
      ),
    );
    expect(find.text('Tabla no disponible'), findsOneWidget);
    expect(find.byKey(const ValueKey('standings-compact')), findsNothing);
  });

  testWidgets('unresolved groups: Tabla no disponible (no switch)', (
    tester,
  ) async {
    await _pump(
      tester,
      _matchTab(
        _snapshot(grouped: true, groupsResolved: false),
        home: 'fb_team_tv2_a1',
        away: 'fb_team_tv2_c2',
      ),
      repository: ApiRepository(_FormServer().dio()),
    );
    expect(find.text('Tabla no disponible'), findsOneWidget);
    expect(find.byKey(const ValueKey('standings-view-form')), findsNothing);
    expect(find.text('Equipo'), findsNothing);
  });

  testWidgets('Forma: lazy single read, real chips newest first, dash '
      'without data', (tester) async {
    final server = _FormServer()..gate = Completer<void>();
    await _pump(
      tester,
      _matchTab(_snapshot(), home: 'fb_team_tv2_a1', away: 'fb_team_tv2_a2'),
      repository: ApiRepository(server.dio()),
    );
    expect(server.reads, 0);
    await tester.tap(find.byKey(const ValueKey('standings-view-form')));
    await _settle(tester);
    expect(server.reads, 1);
    expect(server.lastQuery, {'competitionId': _comp, 'season': '2026'});
    expect(find.byKey(const ValueKey('standings-form-loading')), findsOne);
    server.gate!.complete();
    await _settle(tester);
    expect(find.byKey(const ValueKey('standings-form-loading')), findsNothing);
    expect(_chipLetters(tester, 'fb_team_tv2_a1'), ['G', 'E', 'P']);
    expect(_chipLetters(tester, 'fb_team_tv2_a2'), ['P', 'P', 'G', 'G', 'E']);
    // No data: a neutral dash, never an invented result.
    for (final id in ['fb_team_tv2_a3', 'fb_team_tv2_a4']) {
      expect(find.byKey(ValueKey('standings-form-none-$id')), findsOneWidget);
      expect(find.byKey(ValueKey('standings-form-$id')), findsNothing);
    }
    expect(_accent(tester, 'fb_team_tv2_a1'), lime);
    expect(_accent(tester, 'fb_team_tv2_a2'), awaySideColor);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Forma failure: Reintentar, no endless spinner, then loads', (
    tester,
  ) async {
    final server = _FormServer(fail: 1);
    await _pump(
      tester,
      _matchTab(_snapshot(), home: 'fb_team_tv2_a1', away: 'fb_team_tv2_a2'),
      repository: ApiRepository(server.dio()),
    );
    await tester.tap(find.byKey(const ValueKey('standings-view-form')));
    await _settle(tester);
    expect(server.reads, 1, reason: 'one attempt only');
    expect(find.text('Reintentar'), findsOneWidget);
    expect(find.byKey(const ValueKey('standings-form-loading')), findsNothing);
    // Other views keep working meanwhile.
    await tester.tap(find.byKey(const ValueKey('standings-view-compact')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('standings-compact')), findsOneWidget);
    expect(server.reads, 1);
    await tester.tap(find.byKey(const ValueKey('standings-view-form')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('standings-form-retry')));
    await _settle(tester);
    expect(server.reads, 2);
    expect(find.text('Reintentar'), findsNothing);
    expect(_chipLetters(tester, 'fb_team_tv2_a1'), ['G', 'E', 'P']);
  });

  testWidgets('Forma hidden without the cloud repository or a season', (
    tester,
  ) async {
    await _pump(
      tester,
      _matchTab(_snapshot(), home: 'fb_team_tv2_a1', away: 'fb_team_tv2_a2'),
      repository: DemoRepository(),
    );
    expect(find.byKey(const ValueKey('standings-view-full')), findsOneWidget);
    expect(find.byKey(const ValueKey('standings-view-form')), findsNothing);
    // An unlabelled table is never given the competition's CURRENT season
    // (at a rollover it may be last season's table): Forma is hidden.
    await _pump(
      tester,
      _matchTab(
        _snapshot(tableSeason: ''),
        home: 'fb_team_tv2_a1',
        away: 'fb_team_tv2_a2',
      ),
      repository: ApiRepository(_FormServer().dio()),
    );
    expect(find.byKey(const ValueKey('standings-view-full')), findsOneWidget);
    expect(find.byKey(const ValueKey('standings-view-form')), findsNothing);
  });

  test(
    'Forma season: seasonKey, else the table label, never the competition',
    () {
      expect(
        standingsSeason({'seasonKey': '2025-2026', 'season': ''}),
        '2025-2026',
      );
      expect(standingsSeason({'season': '2025/26'}), '2025/26');
      expect(standingsSeason({'season': ''}), isNull);
      expect(standingsSeason({'season': '   '}), isNull);
    },
  );

  testWidgets('Forma is capped at a published table updatedAt; provisional '
      'and seasonKey tables read without a cap', (tester) async {
    final published = _FormServer();
    await _pump(
      tester,
      _matchTab(
        _snapshot(updatedAt: '2026-09-20T04:00:00-06:00', provisional: false),
        home: 'fb_team_tv2_a1',
        away: 'fb_team_tv2_a2',
      ),
      repository: ApiRepository(published.dio()),
    );
    await tester.tap(find.byKey(const ValueKey('standings-view-form')));
    await _settle(tester);
    expect(published.lastQuery, {
      'competitionId': _comp,
      'season': '2026',
      'until': '2026-09-20T10:00:00.000Z',
    });
    final provisional = _FormServer();
    await _pump(
      tester,
      _matchTab(
        _snapshot(
          tableSeason: '',
          seasonKey: '2025-2026',
          updatedAt: '2026-09-20T10:00:00Z',
          provisional: true,
        ),
        home: 'fb_team_tv2_a1',
        away: 'fb_team_tv2_a2',
      ),
      repository: ApiRepository(provisional.dio()),
    );
    await tester.tap(find.byKey(const ValueKey('standings-view-form')));
    await _settle(tester);
    expect(provisional.lastQuery, {
      'competitionId': _comp,
      'season': '2025-2026',
    });
    // A legacy, unparseable updatedAt is never sent (no permanent 400).
    final legacy = _FormServer();
    await _pump(
      tester,
      _matchTab(
        _snapshot(updatedAt: 'ayer', provisional: false),
        home: 'fb_team_tv2_a1',
        away: 'fb_team_tv2_a2',
      ),
      repository: ApiRepository(legacy.dio()),
    );
    await tester.tap(find.byKey(const ValueKey('standings-view-form')));
    await _settle(tester);
    expect(legacy.lastQuery, {'competitionId': _comp, 'season': '2026'});
    expect(_chipLetters(tester, 'fb_team_tv2_a1'), ['G', 'E', 'P']);
  });

  testWidgets('Forma of a row stored under an alias id: resolved canonically', (
    tester,
  ) async {
    await _pump(
      tester,
      _matchTab(
        _snapshot(rowAliases: {'fb_team_tv2_a1': 'fb_team_tv2_old1'}),
        home: 'fb_team_tv2_a2',
        away: 'fb_team_tv2_a3',
      ),
      repository: ApiRepository(_FormServer().dio()),
    );
    await tester.tap(find.byKey(const ValueKey('standings-view-form')));
    await _settle(tester);
    expect(_chipLetters(tester, 'fb_team_tv2_old1'), ['G', 'E', 'P']);
    expect(
      find.byKey(const ValueKey('standings-form-none-fb_team_tv2_old1')),
      findsNothing,
    );
  });

  test('a team in two groups (group + ranking of thirds): its own group, or '
      'fail closed', () {
    // Grupo A plus a ranking of third-placed teams holding a3 and b3.
    final thirds = [
      _row('fb_team_tv2_a3', 1, group: 'Mejores terceros'),
      _row('fb_team_tv2_b3', 2, group: 'Mejores terceros'),
    ];
    final data = _snapshot(grouped: true, extraRows: thirds);
    final table = standingsTableFor(data, _comp);
    List<String?>? labels(Set<String> focus) => standingsGroups(
      table,
      data,
      focusTeamIds: focus,
    )?.map((g) => g.label).toList();
    // One group holds both teams: only that group (old rule).
    expect(labels({'fb_team_tv2_a1', 'fb_team_tv2_a3'}), ['Grupo A']);
    expect(labels({'fb_team_tv2_a3'}), isNull, reason: 'A and the ranking');
    // Only the ranking holds both teams: that table.
    expect(labels({'fb_team_tv2_a3', 'fb_team_tv2_b3'}), ['Mejores terceros']);
    // Cross-group where a team sits in two candidate groups: fail closed.
    expect(labels({'fb_team_tv2_a3', 'fb_team_tv2_c1'}), isNull);
    // Two groups hold both teams: ambiguous, fail closed.
    final both = _snapshot(
      grouped: true,
      extraRows: [
        _row('fb_team_tv2_a1', 1, group: 'Mejores terceros'),
        _row('fb_team_tv2_a3', 2, group: 'Mejores terceros'),
      ],
    );
    expect(
      standingsGroups(
        standingsTableFor(both, _comp),
        both,
        focusTeamIds: {'fb_team_tv2_a1', 'fb_team_tv2_a3'},
      ),
      isNull,
    );
    // Cross-group, each team in exactly one group: both groups.
    expect(labels({'fb_team_tv2_a1', 'fb_team_tv2_c1'}), [
      'Grupo A',
      'Grupo C',
    ]);
  });

  test('StandingsForm keeps only real results', () {
    final form = StandingsForm({
      'schemaVersion': 1,
      'teams': {
        'a': {
          'results': ['WIN', 'X', null, 'LOSS'],
        },
        'b': {'results': <dynamic>[]},
        'c': 'junk',
      },
    });
    expect(form.results('a'), ['WIN', 'LOSS']);
    expect(form.results('b'), isEmpty);
    expect(form.results('c'), isEmpty);
    expect(form.results('missing'), isEmpty);
  });

  testWidgets('team profile: the single focus team is highlighted', (
    tester,
  ) async {
    await _pump(
      tester,
      Standings(
        _snapshot(grouped: true),
        _comp,
        focusTeamIds: {'fb_team_tv2_b2'},
      ),
    );
    expect(find.byKey(const ValueKey('standings-group-Grupo B')), findsOne);
    expect(find.byKey(const ValueKey('standings-group-Grupo A')), findsNothing);
    expect(_accent(tester, 'fb_team_tv2_b2'), lime);
    expect(_accent(tester, 'fb_team_tv2_b1'), isNull);
  });

  testWidgets('Posición en la tabla across groups: each side in its group', (
    tester,
  ) async {
    final data = _snapshot(
      grouped: true,
      matches: [
        {
          'id': 'fb_match_tv2_ko',
          'competitionId': _comp,
          'homeTeamId': 'fb_team_tv2_a1',
          'awayTeamId': 'fb_team_tv2_c2',
          'startTime': DateTime.now()
              .toUtc()
              .add(const Duration(days: 2))
              .toIso8601String(),
          'status': 'SCHEDULED',
          'events': <dynamic>[],
          'statistics': <dynamic>[],
        },
      ],
    );
    await _pump(
      tester,
      StandingsSnapshotCard(data: data, match: data.matches.single),
    );
    expect(find.byKey(const ValueKey('standings-snapshot')), findsOneWidget);
    expect(find.text('Grupo A'), findsOneWidget);
    expect(find.text('Grupo C'), findsOneWidget);
    expect(find.text('#1'), findsOneWidget);
    expect(find.text('#2'), findsOneWidget);
  });

  testWidgets('Posición en la tabla: a team also in a ranking keeps its own '
      'group position', (tester) async {
    final data = _snapshot(
      grouped: true,
      extraRows: [
        _row('fb_team_tv2_a3', 1, group: 'Mejores terceros'),
        _row('fb_team_tv2_b3', 2, group: 'Mejores terceros'),
      ],
      matches: [
        {
          'id': 'fb_match_tv2_grp',
          'competitionId': _comp,
          'homeTeamId': 'fb_team_tv2_a1',
          'awayTeamId': 'fb_team_tv2_a3',
          'startTime': DateTime.now()
              .toUtc()
              .add(const Duration(days: 2))
              .toIso8601String(),
          'status': 'SCHEDULED',
          'events': <dynamic>[],
          'statistics': <dynamic>[],
        },
      ],
    );
    await _pump(
      tester,
      StandingsSnapshotCard(data: data, match: data.matches.single),
    );
    expect(find.text('#1'), findsOneWidget);
    expect(find.text('#3'), findsOneWidget);
    expect(find.text('Mejores terceros'), findsNothing);
    expect(find.text('Grupo A'), findsNothing);
  });
}

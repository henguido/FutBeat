import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/team_matches.dart';
import 'package:futbeat/features/entities/entity_screen.dart';
import 'package:futbeat/features/entities/standings.dart';
import 'package:go_router/go_router.dart';

// #150 / #111. Synthetic fixtures only: no real team or competition.

String _at(Duration offset) =>
    DateTime.now().toUtc().add(offset).toIso8601String();

Map<String, dynamic> _team(String id, String name, {String? competition}) => {
  'id': id,
  'name': name,
  'country': 'Nowhere',
  'competitionId': ?competition,
};

Map<String, dynamic> _match(
  String id,
  Duration offset, {
  String comp = 'fb_comp_a',
  String home = 'fb_team',
  String away = 'fb_rival',
  String status = 'SCHEDULED',
  Map<String, dynamic>? score,
}) => {
  'id': id,
  'competitionId': comp,
  'homeTeamId': home,
  'awayTeamId': away,
  'startTime': _at(offset),
  'status': status,
  'score': ?score,
  'events': <dynamic>[],
  'statistics': <dynamic>[],
};

Map<String, dynamic> _row(String team, int position, {String? group}) => {
  'teamId': team,
  'position': position,
  'group': ?group,
  'played': 3,
  'won': 3 - position,
  'drawn': 0,
  'lost': position - 1,
  'gf': 5,
  'ga': 2,
  'points': 9 - position * 3,
};

Map<String, dynamic> _snapshot({
  List<Map<String, dynamic>> matches = const [],
  List<Map<String, dynamic>> standings = const [],
  List<Map<String, dynamic>> extraTeams = const [],
  List<Map<String, dynamic>> players = const [],
  String? squadState,
  String teamName = 'Selección Sintética',
  String? teamCompetition,
  Map<String, dynamic>? page,
}) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': _at(Duration.zero),
  if (squadState != null)
    'coverage': {
      'squad': {'state': squadState},
    },
  'competitions': [
    {'id': 'fb_comp_a', 'name': 'Eliminatoria Sintética', 'country': 'Nowhere'},
    {'id': 'fb_comp_b', 'name': 'Copa Sintética', 'country': 'Nowhere'},
  ],
  'teams': [
    _team('fb_team', teamName, competition: teamCompetition),
    _team('fb_rival', 'Rival Sintético'),
    ...extraTeams,
  ],
  'players': players,
  'standings': standings,
  'matches': matches,
  'news': <dynamic>[],
  'transfers': <dynamic>[],
  ...?page,
};

class _FakeTeamApi extends ApiRepository {
  _FakeTeamApi(this.pages, {this.fail = false}) : super(Dio());

  /// bucket -> cursor (null = first page) -> page json.
  final Map<String, Map<String?, Map<String, dynamic>>> pages;
  final bool fail;
  final calls = <String>[];

  @override
  Future<TeamMatchesPage> loadTeamMatches(
    String teamId,
    String bucket, {
    String? cursor,
    int limit = teamMatchesPageSize,
  }) async {
    calls.add('$teamId:$bucket:$cursor');
    if (fail) throw DioException(requestOptions: RequestOptions());
    return TeamMatchesPage(pages[bucket]?[cursor] ?? _page(const []));
  }
}

Map<String, dynamic> _page(
  List<Map<String, dynamic>> matches, {
  String? next,
}) => _snapshot(
  matches: matches,
  page: {'hasMore': next != null, 'nextCursor': next},
);

Future<void> _pump(
  WidgetTester tester,
  Map<String, dynamic> profile, {
  FootballRepository? repository,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final db = AppDatabase(NativeDatabase.memory());
  final router = GoRouter(
    initialLocation: '/team/fb_team',
    routes: [
      GoRoute(
        path: '/team/:id',
        builder: (_, state) =>
            EntityScreen(type: 'team', id: state.pathParameters['id']!),
      ),
    ],
  );
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      entitySnapshotProvider.overrideWith(
        (ref, request) async => Snapshot(profile),
      ),
      followsProvider.overrideWith((ref) => Stream.value({})),
      if (repository != null) repositoryProvider.overrideWithValue(repository),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    router.dispose();
    container.dispose();
    await tester.runAsync(db.close);
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openTab(WidgetTester tester, String label) async {
  final tab = find.descendant(
    of: find.byType(TabBar),
    matching: find.text(label),
  );
  await tester.ensureVisible(tab);
  await tester.pumpAndSettle();
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

/// Vertical order of two texts on screen.
bool _above(WidgetTester tester, Finder a, Finder b) =>
    tester.getTopLeft(a).dy < tester.getTopLeft(b).dy;

void main() {
  group('Partidos', () {
    testWidgets(
      'national team: Próximos and Resultados from every competition',
      (tester) async {
        final api = _FakeTeamApi({
          'upcoming': {
            null: _page([
              _match('m_up1', const Duration(days: 2)),
              _match('m_up2', const Duration(days: 9), comp: 'fb_comp_b'),
            ]),
          },
          'results': {
            null: _page([
              _match(
                'm_res1',
                const Duration(days: -3),
                comp: 'fb_comp_b',
                status: 'VERIFIED',
                score: {'home': 1, 'away': 0},
              ),
            ]),
          },
        });
        // The profile itself only knew one match: the pages bring the rest.
        await _pump(
          tester,
          _snapshot(matches: [_match('m_up1', const Duration(days: 2))]),
          repository: api,
        );
        await _openTab(tester, 'Partidos');
        expect(api.calls, [
          'fb_team:live:null',
          'fb_team:upcoming:null',
          'fb_team:results:null',
        ]);
        // Nothing in play: no "En vivo" section at all.
        expect(find.text('En vivo'), findsNothing);
        expect(find.text('Próximos'), findsOneWidget);
        expect(find.text('Resultados'), findsOneWidget);
        expect(find.text('FINALIZADO'), findsOneWidget);
        expect(find.text('PROGRAMADO'), findsNWidgets(2));
        expect(find.byType(CircularProgressIndicator), findsNothing);
      },
    );

    testWidgets('club: cache-first split without the paginated API', (
      tester,
    ) async {
      await _pump(
        tester,
        _snapshot(
          teamName: 'Club Sintético',
          matches: [
            _match('m_next', const Duration(days: 1)),
            _match(
              'm_old',
              const Duration(days: -7),
              status: 'VERIFIED',
              score: {'home': 0, 'away': 0},
            ),
          ],
        ),
      );
      await _openTab(tester, 'Partidos');
      expect(
        _above(tester, find.text('Próximos'), find.text('PROGRAMADO')),
        isTrue,
      );
      expect(
        _above(tester, find.text('PROGRAMADO'), find.text('Resultados')),
        isTrue,
      );
      expect(
        _above(tester, find.text('Resultados'), find.text('FINALIZADO')),
        isTrue,
      );
    });

    testWidgets('Ver más loads the next page once, without duplicates', (
      tester,
    ) async {
      final done = {'status': 'VERIFIED'};
      final api = _FakeTeamApi({
        'upcoming': {null: _page(const [])},
        'results': {
          null: _page([
            {..._match('m_r1', const Duration(days: -1)), ...done},
            {..._match('m_r2', const Duration(days: -2)), ...done},
          ], next: 'c1'),
          'c1': _page([
            // m_r2 again (page boundary race) must not duplicate.
            {..._match('m_r2', const Duration(days: -2)), ...done},
            {..._match('m_r3', const Duration(days: -30)), ...done},
          ]),
        },
      });
      await _pump(tester, _snapshot(), repository: api);
      await _openTab(tester, 'Partidos');
      expect(find.text('FINALIZADO'), findsNWidgets(2));
      final more = find.byKey(const ValueKey('team-matches-more-results'));
      expect(more, findsOneWidget);
      await tester.ensureVisible(more);
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(api.calls.last, 'fb_team:results:c1');
      await tester.scrollUntilVisible(
        find.text('FINALIZADO').last,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      final texts = tester
          .widgetList<Text>(find.textContaining('FINALIZADO'))
          .length;
      expect(texts, 3);
      expect(more, findsNothing);
      expect(find.text('Sin partidos próximos'), findsOneWidget);
    });

    testWidgets(
      'a past kickoff still SCHEDULED is never a normal upcoming match',
      (tester) async {
        await _pump(
          tester,
          _snapshot(matches: [_match('m_stale', const Duration(hours: -3))]),
        );
        await _openTab(tester, 'Partidos');
        expect(find.text('Sin partidos próximos'), findsOneWidget);
        expect(find.textContaining('Por confirmar'), findsOneWidget);
        expect(
          _above(
            tester,
            find.text('Resultados'),
            find.textContaining('Por confirmar'),
          ),
          isTrue,
        );
      },
    );

    testWidgets(
      'a failed page never leaves a spinner and keeps the profile matches',
      (tester) async {
        final api = _FakeTeamApi(const {}, fail: true);
        await _pump(
          tester,
          _snapshot(matches: [_match('m_next', const Duration(days: 1))]),
          repository: api,
        );
        await _openTab(tester, 'Partidos');
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.text('PROGRAMADO'), findsOneWidget);
        expect(find.text('Reintentar'), findsNWidgets(2));
      },
    );

    testWidgets('a live match is under "En vivo", never under "Próximos"', (
      tester,
    ) async {
      final api = _FakeTeamApi({
        'live': {
          null: _page([
            _match('m_live', const Duration(minutes: -40), status: 'HALFTIME'),
          ]),
        },
        'upcoming': {
          null: _page([_match('m_next', const Duration(days: 1))]),
        },
      });
      await _pump(tester, _snapshot(), repository: api);
      await _openTab(tester, 'Partidos');
      final live = find.text('DESCANSO');
      expect(live, findsOneWidget);
      expect(_above(tester, find.text('En vivo'), live), isTrue);
      expect(_above(tester, live, find.text('Próximos')), isTrue);
      expect(
        _above(tester, find.text('Próximos'), find.text('PROGRAMADO')),
        isTrue,
      );
    });

    test('bucket helper orders and dedupes by effective status', () {
      final data = Snapshot(
        _snapshot(
          matches: [
            _match('late', const Duration(days: 5)),
            _match('soon', const Duration(days: 1)),
            _match('stale', const Duration(hours: -2)),
            _match('live', const Duration(minutes: -30), status: 'LIVE'),
            _match('old', const Duration(days: -9), status: 'VERIFIED'),
            _match('recent', const Duration(days: -1), status: 'POSTPONED'),
          ],
        ),
      );
      final items = [for (final m in data.matches) (match: m, data: data)];
      List<String> ids(TeamMatchesBucket b) => [
        for (final item in orderedProfileMatches(b, [...items, ...items]))
          item.match.id,
      ];
      expect(ids(TeamMatchesBucket.live), ['live']);
      expect(ids(TeamMatchesBucket.upcoming), ['soon', 'late']);
      expect(ids(TeamMatchesBucket.results), ['stale', 'recent', 'old']);
    });
  });

  group('Plantilla', () {
    for (final state in [null, 'PENDING']) {
      testWidgets('squad $state says pending, never "no disponible"', (
        tester,
      ) async {
        await _pump(tester, _snapshot(squadState: state));
        await _openTab(tester, 'Plantilla');
        expect(find.text('Plantilla pendiente'), findsOneWidget);
        expect(find.text('Plantilla no disponible'), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
      });
    }

    for (final state in ['CONFIRMED_EMPTY', 'UNAVAILABLE']) {
      testWidgets('squad $state says "Plantilla no disponible"', (
        tester,
      ) async {
        await _pump(tester, _snapshot(squadState: state));
        await _openTab(tester, 'Plantilla');
        expect(find.text('Plantilla no disponible'), findsOneWidget);
        expect(find.text('Plantilla pendiente'), findsNothing);
      });
    }

    testWidgets(
      'sections are independent: pending squad, matches still shown',
      (tester) async {
        await _pump(
          tester,
          _snapshot(
            squadState: 'PENDING',
            matches: [_match('m_next', const Duration(days: 1))],
          ),
        );
        // No table: no Tabla tab, and the other tabs still work.
        expect(
          find.descendant(
            of: find.byType(TabBar),
            matching: find.text('Tabla'),
          ),
          findsNothing,
        );
        await _openTab(tester, 'Partidos');
        expect(find.text('PROGRAMADO'), findsOneWidget);
        await _openTab(tester, 'Plantilla');
        expect(find.text('Plantilla pendiente'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('Tabla', () {
    final groupTeams = [
      _team('fb_a2', 'Alfa Dos'),
      _team('fb_b1', 'Beta Uno'),
      _team('fb_b2', 'Beta Dos'),
    ];
    Map<String, dynamic> grouped({bool resolved = true}) => {
      'competitionId': 'fb_comp_a',
      'grouped': true,
      'groupsResolved': resolved,
      'rows': [
        _row('fb_team', 1, group: 'Grupo A'),
        _row('fb_a2', 2, group: 'Grupo A'),
        _row('fb_b1', 1, group: 'Grupo B'),
        _row('fb_b2', 2, group: 'Grupo B'),
      ],
    };

    testWidgets('team profile shows only its own group', (tester) async {
      await _pump(
        tester,
        _snapshot(
          standings: [grouped()],
          extraTeams: groupTeams,
          matches: [_match('m1', const Duration(days: 1))],
        ),
      );
      await _openTab(tester, 'Tabla');
      expect(find.text('Grupo A'), findsOneWidget);
      expect(find.text('Alfa Dos'), findsOneWidget);
      expect(find.text('Beta Uno'), findsNothing);
      expect(find.text('Grupo B'), findsNothing);
    });

    // Two competitions whose tables both contain the team; the rival rows
    // tell which table is shown.
    final twoTables = [
      {
        'competitionId': 'fb_comp_a',
        'rows': [_row('fb_team', 1), _row('fb_a2', 2)],
      },
      {
        'competitionId': 'fb_comp_b',
        'rows': [_row('fb_b1', 1), _row('fb_team', 2)],
      },
    ];

    testWidgets('the main competition wins even when it is not listed first', (
      tester,
    ) async {
      await _pump(
        tester,
        _snapshot(
          standings: twoTables,
          extraTeams: groupTeams,
          teamCompetition: 'fb_comp_b',
          matches: [_match('m1', const Duration(days: 1))],
        ),
      );
      await _openTab(tester, 'Tabla');
      expect(find.text('Beta Uno'), findsOneWidget);
      expect(find.text('Alfa Dos'), findsNothing);
    });

    testWidgets('fallback: the only table containing the team is used', (
      tester,
    ) async {
      await _pump(
        tester,
        _snapshot(
          standings: [
            twoTables.last,
            {
              'competitionId': 'fb_comp_a',
              'rows': [_row('fb_a2', 1), _row('fb_b2', 2)],
            },
          ],
          extraTeams: groupTeams,
          // Main competition's table does not contain the team.
          teamCompetition: 'fb_comp_a',
        ),
      );
      await _openTab(tester, 'Tabla');
      expect(find.text('Beta Uno'), findsOneWidget);
    });

    testWidgets('several candidate tables and no main signal: no Tabla tab', (
      tester,
    ) async {
      for (final order in [twoTables, twoTables.reversed.toList()]) {
        await _pump(
          tester,
          _snapshot(standings: order, extraTeams: groupTeams),
        );
        expect(
          find.descendant(
            of: find.byType(TabBar),
            matching: find.text('Tabla'),
          ),
          findsNothing,
        );
      }
    });

    testWidgets('the main competition keeps the team group only', (
      tester,
    ) async {
      await _pump(
        tester,
        _snapshot(
          standings: [twoTables.last, grouped()],
          extraTeams: groupTeams,
          teamCompetition: 'fb_comp_a',
        ),
      );
      await _openTab(tester, 'Tabla');
      expect(find.text('Grupo A'), findsOneWidget);
      expect(find.text('Grupo B'), findsNothing);
      expect(find.text('Alfa Dos'), findsOneWidget);
    });

    testWidgets('a row without a known team never renders "Equipo"', (
      tester,
    ) async {
      final data = Snapshot(
        _snapshot(
          standings: [
            {
              'competitionId': 'fb_comp_a',
              'rows': [_row('fb_team', 1), _row('fb_unknown', 2)],
            },
          ],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: Standings(data, 'fb_comp_a'))),
      );
      expect(find.text('Tabla no disponible'), findsOneWidget);
      expect(find.text('Equipo'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'an unresolved-groups table hides the Tabla tab, profile intact',
      (tester) async {
        await _pump(
          tester,
          _snapshot(
            standings: [grouped(resolved: false)],
            extraTeams: groupTeams,
            matches: [_match('m1', const Duration(days: 1))],
          ),
        );
        expect(
          find.descendant(
            of: find.byType(TabBar),
            matching: find.text('Tabla'),
          ),
          findsNothing,
        );
        await _openTab(tester, 'Partidos');
        expect(find.text('PROGRAMADO'), findsOneWidget);
      },
    );

    testWidgets('competition view lists every group as its own table', (
      tester,
    ) async {
      final data = Snapshot(
        _snapshot(standings: [grouped()], extraTeams: groupTeams),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: Standings(data, 'fb_comp_a')),
          ),
        ),
      );
      expect(find.text('Grupo A'), findsOneWidget);
      expect(find.text('Grupo B'), findsOneWidget);
      // Header "Equipo" once per group table; never as a row name.
      expect(find.text('Equipo'), findsNWidgets(2));
      expect(
        _above(tester, find.text('Alfa Dos'), find.text('Grupo B')),
        isTrue,
      );
    });

    test('group resolution: match group, cross-group and duplicates', () {
      final data = Snapshot(
        _snapshot(standings: [grouped()], extraTeams: groupTeams),
      );
      final table = standingsTableFor(data, 'fb_comp_a');
      expect(
        standingsGroups(
          table,
          data,
          focusTeamIds: {'fb_b1', 'fb_b2'},
        )!.single.label,
        'Grupo B',
      );
      // Teams from different groups: no single correct table.
      expect(
        standingsGroups(table, data, focusTeamIds: {'fb_team', 'fb_b1'}),
        isNull,
      );
      expect(standingsGroups(table, data)!.length, 2);
      // Unlabelled groups sent together: repeated positions -> unavailable.
      final mixed = {
        'competitionId': 'fb_comp_a',
        'rows': [
          _row('fb_team', 1),
          _row('fb_a2', 2),
          _row('fb_b1', 1),
          _row('fb_b2', 2),
        ],
      };
      expect(standingsGroups(mixed, data), isNull);
    });
  });

  test('mobile never calls a football provider directly', () {
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final source = file.readAsStringSync().toLowerCase();
      for (final host in [
        'api.goal-api.com',
        'goal-api.com/v1',
        'api-football',
        'apifootball',
        'rapidapi',
        'thesportsdb',
      ]) {
        if (source.contains(host)) offenders.add('${file.path}: $host');
      }
    }
    expect(offenders, isEmpty);
  });
}

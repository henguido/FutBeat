import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/profile_context.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/team_matches.dart';
import 'package:futbeat/features/entities/entity_screen.dart';
import 'package:futbeat/features/entities/standings.dart';
import 'package:go_router/go_router.dart';

// #161: competition + season context of a team profile. Synthetic ids and
// names only.

String _at(Duration offset) =>
    DateTime.now().toUtc().add(offset).toIso8601String();

const _nations = 'fb_comp_ctx_nations';
const _cup = 'fb_comp_ctx_cup';
const _friendly = 'fb_comp_ctx_friendly';

Map<String, dynamic> _team(String id, String name) => {
  'id': id,
  'name': name,
  'country': 'Nowhere',
};

Map<String, dynamic> _match(
  String id,
  Duration offset, {
  String comp = _nations,
  String? season,
  String status = 'VERIFIED',
}) => {
  'id': id,
  'competitionId': comp,
  'season': ?season,
  'homeTeamId': 'fb_team',
  'awayTeamId': 'fb_rival',
  'startTime': _at(offset),
  'status': status,
  if (status == 'VERIFIED') 'score': {'home': 1, 'away': 0},
  'events': <dynamic>[],
  'statistics': <dynamic>[],
};

Map<String, dynamic> _table(String comp, String season, List<String> teams) => {
  'competitionId': comp,
  'season': season,
  'rows': [
    for (var i = 0; i < teams.length; i++)
      {
        'teamId': teams[i],
        'position': i + 1,
        'played': 4,
        'won': 4 - i,
        'drawn': 0,
        'lost': i,
        'gf': 8,
        'ga': 2,
        'points': 12 - i * 3,
      },
  ],
};

final _competitions = [
  {'id': _nations, 'name': 'Liga de Naciones Sintética'},
  {'id': _cup, 'name': 'Copa Sintética'},
  {'id': _friendly, 'name': 'Amistosos Sintéticos'},
];

Map<String, dynamic> _snapshot({
  List<Map<String, dynamic>> matches = const [],
  List<Map<String, dynamic>> standings = const [],
  Map<String, dynamic>? page,
}) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': _at(Duration.zero),
  'competitions': _competitions,
  'teams': [_team('fb_team', 'Selección Contexto'), _team('fb_rival', 'Rival')],
  'players': <dynamic>[],
  'standings': standings,
  'matches': matches,
  'news': <dynamic>[],
  'transfers': <dynamic>[],
  ...?page,
};

final _options = [
  {
    'competitionId': _nations,
    'competitionName': 'Liga de Naciones Sintética',
    'seasonKey': '2026-2027',
    'matchCount': 3,
    'hasStandings': true,
  },
  {
    'competitionId': _cup,
    'competitionName': 'Copa Sintética',
    'seasonKey': '2026',
    'matchCount': 1,
    'hasStandings': false,
  },
  {
    'competitionId': _nations,
    'competitionName': 'Liga de Naciones Sintética',
    'seasonKey': '2024-2025',
    'matchCount': 2,
    'hasStandings': true,
  },
  {
    'competitionId': _friendly,
    'competitionName': 'Amistosos Sintéticos',
    'matchCount': 1,
    'hasStandings': false,
  },
];

class _FakeContextApi extends ApiRepository {
  _FakeContextApi({
    this.failContext = false,
    this.coverageState,
    this.historyRequested = false,
  }) : super(Dio());

  final bool failContext;
  final String? coverageState;
  final bool historyRequested;
  final contextCalls = <String>[];
  final matchCalls = <String>[];

  @override
  Future<TeamContext> loadTeamContext(
    String teamId, {
    String? competitionId,
    String? season,
  }) async {
    contextCalls.add('${competitionId ?? '-'}|${season ?? '-'}');
    if (failContext) throw DioException(requestOptions: RequestOptions());
    // Requested when real, else the default (current Nations League).
    final requested = _options.where(
      (o) =>
          o['competitionId'] == competitionId &&
          (season == null ||
              o['seasonKey'] == season ||
              (season == noSeason && o['seasonKey'] == null)),
    );
    final selected = requested.firstOrNull ?? _options.first;
    final key = selected['seasonKey'];
    final table = selected['competitionId'] == _nations
        ? _table(
            _nations,
            key == '2024-2025' ? '2024/25' : '2026/27',
            key == '2024-2025'
                ? ['fb_old_leader', 'fb_team']
                : ['fb_team', 'fb_rival'],
          )
        : null;
    return TeamContext({
      'schemaVersion': 1,
      'teamId': teamId,
      'options': _options,
      'selected': {
        'competitionId': selected['competitionId'],
        'seasonKey': ?key,
        'requested': requested.isNotEmpty,
      },
      'standings': [?table],
      'teams': [
        _team('fb_team', 'Selección Contexto'),
        _team('fb_rival', 'Rival'),
        _team('fb_old_leader', 'Líder Antiguo'),
      ],
      'competitions': _competitions,
    });
  }

  @override
  Future<TeamMatchesPage> loadTeamMatches(
    String teamId,
    String bucket, {
    String? cursor,
    int limit = teamMatchesPageSize,
    String? competitionId,
    String? season,
  }) async {
    matchCalls.add('$bucket|${competitionId ?? '-'}|${season ?? '-'}');
    final all = [
      _match('fb_match_n1', const Duration(days: -10), season: '2026/27'),
      _match(
        'fb_match_c1',
        const Duration(days: -20),
        comp: _cup,
        season: '2026',
      ),
    ];
    final rows = bucket != 'results'
        ? const <Map<String, dynamic>>[]
        : [
            for (final m in all)
              if (competitionId == null ||
                  (m['competitionId'] == competitionId &&
                      (normalizeSeasonKey(m['season'] as String?) ??
                              noSeason) ==
                          season))
                m,
          ];
    return TeamMatchesPage(
      _snapshot(
        matches: coverageState == null ? rows : const [],
        page: {
          'hasMore': false,
          'nextCursor': null,
          if (coverageState != null)
            'coverage': {
              'teamMatches': {
                'state': coverageState,
                if (historyRequested && bucket == 'results')
                  'history': 'requested',
              },
            },
        },
      ),
    );
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Map<String, dynamic> profile,
  FootballRepository repository, {
  String location = '/team/fb_team',
  ProviderContainer? reuse,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: '/team/:id',
        builder: (_, state) => EntityScreen(
          type: 'team',
          id: state.pathParameters['id']!,
          competitionId: state.uri.queryParameters['competitionId'],
          season: state.uri.queryParameters['season'],
        ),
      ),
    ],
  );
  final container =
      reuse ??
      ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(
            AppDatabase(NativeDatabase.memory()),
          ),
          entitySnapshotProvider.overrideWith(
            (ref, request) async => Snapshot(profile),
          ),
          followsProvider.overrideWith((ref) => Stream.value({})),
          repositoryProvider.overrideWithValue(repository),
        ],
      );
  addTearDown(router.dispose);
  if (reuse == null) {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      final db = container.read(databaseProvider);
      container.dispose();
      await tester.runAsync(db.close);
    });
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

String _label(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('profile-context-label')))
    .data!;

Future<void> _openTab(WidgetTester tester, String tab) async {
  await tester.tap(find.widgetWithText(Tab, tab));
  await tester.pumpAndSettle();
}

void main() {
  test('season keys follow the server normalization', () {
    expect(normalizeSeasonKey('2025/26'), '2025-2026');
    expect(normalizeSeasonKey(' 2025-26 '), '2025-2026');
    expect(normalizeSeasonKey('2099/00'), '2099-2100');
    expect(normalizeSeasonKey('2026'), '2026');
    expect(normalizeSeasonKey('Apertura  2026'), 'apertura 2026');
    expect(normalizeSeasonKey(''), isNull);
    expect(normalizeSeasonKey(null), isNull);
    expect(seasonLabel('2025-2026'), '2025/26');
    expect(seasonLabel('2026'), '2026');
  });

  test('the context table carries the selected season key for Forma, never '
      'overriding one the table already has', () {
    TeamContext ctx(Map<String, dynamic> table) => TeamContext({
      'schemaVersion': 1,
      'teamId': 'fb_team',
      'options': _options,
      'selected': {'competitionId': _nations, 'seasonKey': '2024-2025'},
      'standings': [table],
      'teams': const <dynamic>[],
    });
    final data = Snapshot(_snapshot());
    final unlabelled = ctx({
      ..._table(_nations, '', ['fb_team']),
      'season': '',
    }).tableSnapshot(data).standings.single;
    expect(unlabelled['seasonKey'], '2024-2025');
    expect(standingsSeason(unlabelled), '2024-2025');
    final labelled = ctx({
      ..._table(_nations, '2024/25', ['fb_team']),
      'seasonKey': '2024-2025',
    }).tableSnapshot(data).standings.single;
    expect(labelled['seasonKey'], '2024-2025');
  });

  testWidgets('the selector shows only real options, grouped by season, and '
      'drives the exact season table', (tester) async {
    final api = _FakeContextApi();
    // The profile's own (current) table must never stand in for another
    // season.
    await _pump(
      tester,
      _snapshot(
        standings: [
          _table(_nations, '2026/27', ['fb_team']),
        ],
      ),
      api,
    );
    expect(api.contextCalls, ['-|-']);
    expect(_label(tester), 'Liga de Naciones Sintética 2026/27');
    await tester.tap(find.byKey(const ValueKey('profile-context-selector')));
    await tester.pumpAndSettle();
    expect(find.text('Temporada'), findsOneWidget);
    for (final header in ['2026/27', '2026', '2024/25', 'Sin temporada']) {
      expect(find.text(header), findsWidgets);
    }
    expect(
      find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith(
              'profile-context-option-',
            ),
      ),
      findsNWidgets(4),
    );
    await tester.tap(
      find.byKey(const ValueKey('profile-context-option-$_nations|2024-2025')),
    );
    await tester.pumpAndSettle();
    expect(api.contextCalls.last, '$_nations|2024-2025');
    expect(_label(tester), 'Liga de Naciones Sintética 2024/25');
    await _openTab(tester, 'Tabla');
    expect(find.text('Líder Antiguo'), findsOneWidget);
    expect(find.text('Rival'), findsNothing);
    // Switching season while on Tabla stays on Tabla (no tab reset).
    await tester.tap(find.byKey(const ValueKey('profile-context-selector')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('profile-context-option-$_nations|2026-2027')),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('profile-context-selector')), findsOne);
    await tester.pumpAndSettle();
    expect(
      DefaultTabController.of(
        tester.element(find.byKey(const ValueKey('profile-context-label'))),
      ).index,
      2,
    );
    expect(find.text('Rival'), findsWidgets);
    expect(find.text('Líder Antiguo'), findsNothing);
  });

  testWidgets('a context without its table says so; never another season', (
    tester,
  ) async {
    final api = _FakeContextApi();
    await _pump(
      tester,
      _snapshot(
        standings: [
          _table(_nations, '2026/27', ['fb_team']),
        ],
      ),
      api,
      location: '/team/fb_team?competitionId=$_cup&season=2026',
    );
    expect(api.contextCalls.first, '$_cup|2026', reason: 'opened from a match');
    expect(_label(tester), 'Copa Sintética 2026');
    await _openTab(tester, 'Tabla');
    expect(
      find.byKey(const ValueKey('profile-context-no-table')),
      findsOneWidget,
    );
    expect(find.text('Tabla no disponible'), findsOneWidget);
  });

  testWidgets('a cached table of another season never stands in for the '
      'selected current season', (tester) async {
    final api = _FakeContextApi();
    // Current Nations League season selected, no archived table for it
    // (the Cup has none either); the profile only has LAST season's table.
    await _pump(
      tester,
      _snapshot(
        standings: [
          _table(_cup, '2025', ['fb_old_leader', 'fb_team']),
        ],
      ),
      api,
      location: '/team/fb_team?competitionId=$_cup&season=2026',
    );
    await _openTab(tester, 'Tabla');
    expect(find.text('Tabla no disponible'), findsOneWidget);
    expect(find.text('Líder Antiguo'), findsNothing);
  });

  testWidgets('the choice is kept for the session', (tester) async {
    final api = _FakeContextApi();
    final container = await _pump(tester, _snapshot(), api);
    await tester.tap(find.byKey(const ValueKey('profile-context-selector')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('profile-context-option-$_friendly|')),
    );
    await tester.pumpAndSettle();
    expect(_label(tester), 'Amistosos Sintéticos');
    // Reopen the profile (even from a match of another competition).
    await tester.pumpWidget(const SizedBox());
    await _pump(
      tester,
      _snapshot(),
      api,
      location: '/team/fb_team?competitionId=$_cup&season=2026',
      reuse: container,
    );
    expect(_label(tester), 'Amistosos Sintéticos');
    expect(api.contextCalls.last, '$_friendly|$noSeason');
  });

  testWidgets('Partidos: Todos by default; the context chip narrows every '
      'bucket to that competition + season', (tester) async {
    final api = _FakeContextApi();
    await _pump(tester, _snapshot(), api);
    await _openTab(tester, 'Partidos');
    expect(api.matchCalls.toSet(), {'live|-|-', 'upcoming|-|-', 'results|-|-'});
    api.matchCalls.clear();
    await tester.tap(find.byKey(const ValueKey('team-matches-filter-context')));
    await tester.pumpAndSettle();
    expect(api.matchCalls.toSet(), {
      'live|$_nations|2026-2027',
      'upcoming|$_nations|2026-2027',
      'results|$_nations|2026-2027',
    });
    api.matchCalls.clear();
    await tester.tap(find.byKey(const ValueKey('team-matches-filter-all')));
    await tester.pumpAndSettle();
    expect(api.matchCalls.toSet(), {'live|-|-', 'upcoming|-|-', 'results|-|-'});
  });

  testWidgets('the filtered list keeps its filter while the context changes '
      'and its empty copy follows coverage', (tester) async {
    final api = _FakeContextApi(coverageState: 'PENDING');
    await _pump(tester, _snapshot(), api);
    await _openTab(tester, 'Partidos');
    await tester.tap(find.byKey(const ValueKey('team-matches-filter-context')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('team-matches-empty-results')),
        matching: find.text('Cargando partidos'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('no context (failed read): the profile keeps its own table and '
      'shows no selector', (tester) async {
    final api = _FakeContextApi(failContext: true);
    await _pump(
      tester,
      _snapshot(
        matches: [_match('fb_match_x', const Duration(days: -3))],
        standings: [
          _table(_nations, '2026/27', ['fb_team', 'fb_rival']),
        ],
      ),
      api,
    );
    expect(
      find.byKey(const ValueKey('profile-context-selector')),
      findsNothing,
    );
    await _openTab(tester, 'Tabla');
    expect(find.text('Rival'), findsWidgets);
  });

  testWidgets('a confirmed-empty recent window whose older history is being '
      'asked never reads as a final "Sin resultados"', (tester) async {
    final api = _FakeContextApi(
      coverageState: 'NO_DATA',
      historyRequested: true,
    );
    await _pump(tester, _snapshot(), api);
    await _openTab(tester, 'Partidos');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('team-matches-empty-results')),
        matching: find.text('Cargando historial'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('team-matches-empty-results')),
        matching: find.text('Sin resultados'),
      ),
      findsNothing,
    );
  });

  for (final (state, copy) in [
    ('PENDING', 'Cargando partidos'),
    ('UNAVAILABLE', 'Partidos no disponibles'),
    ('NO_DATA', 'Sin resultados'),
  ]) {
    testWidgets('empty Resultados with coverage $state reads "$copy"', (
      tester,
    ) async {
      final api = _FakeContextApi(coverageState: state);
      await _pump(tester, _snapshot(), api);
      await _openTab(tester, 'Partidos');
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byKey(const ValueKey('team-matches-empty-results')),
                matching: find.byType(Text),
              ),
            )
            .data,
        copy,
      );
    });
  }
}

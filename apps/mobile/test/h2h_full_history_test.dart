import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/match_preview_sections.dart';

// #155: the whole stored head-to-head, paged. Synthetic ids/names only.

const _home = 'fb_team_fh_home';
const _away = 'fb_team_fh_away';
const _liga = 'fb_comp_fh_liga';
const _copa = 'fb_comp_fh_copa';
const _target = 'fb_match_fh_target';

String _at(int days) =>
    DateTime.utc(2026, 9, 1).add(Duration(days: days)).toIso8601String();

Map<String, dynamic> _meeting(int i, {String comp = _liga}) => {
  'matchId': 'fb_match_fh${i.toString().padLeft(3, '0')}',
  'competitionId': comp,
  'startTime': _at(-10 * i),
  'status': 'VERIFIED',
  'homeTeamId': i.isEven ? _away : _home,
  'awayTeamId': i.isEven ? _home : _away,
  'score': {'home': 1, 'away': 0},
};

/// Meetings 1..n (newest first); every third one in the cup.
List<Map<String, dynamic>> _history(int n) => [
  for (var i = 1; i <= n; i++) _meeting(i, comp: i % 3 == 0 ? _copa : _liga),
];

Map<String, dynamic> _totals(List<Map<String, dynamic>> rows) {
  var homeWins = 0, awayWins = 0;
  for (final m in rows) {
    // 1-0 to the side playing at home: count by team id.
    if (m['homeTeamId'] == _home) {
      homeWins++;
    } else {
      awayWins++;
    }
  }
  return {
    'homeWins': homeWins,
    'draws': 0,
    'awayWins': awayWins,
    'counted': rows.length,
  };
}

Map<String, dynamic> _preview(
  List<Map<String, dynamic>> all, {
  String? verifiedFrom,
}) {
  final league = [
    for (final m in all)
      if (m['competitionId'] == _liga) m,
  ];
  return {
    'schemaVersion': 1,
    'matchId': _target,
    'homeTeamId': _home,
    'awayTeamId': _away,
    'h2h': {
      'availability': 'AVAILABLE',
      'competitionId': _liga,
      'coverage': {'verifiedFrom': ?verifiedFrom},
      'meetings': all.take(20).toList(),
      'totals': _totals(all),
      'competitionTotals': {'competitionId': _liga, ..._totals(league)},
    },
    'matches': <dynamic>[],
    'teams': [
      {'id': _home, 'name': 'Equipo Casa'},
      {'id': _away, 'name': 'Equipo Visita'},
    ],
    'competitions': [
      {'id': _liga, 'name': 'Liga Larga'},
      {'id': _copa, 'name': 'Copa Larga'},
    ],
  };
}

class _FakeH2hApi extends ApiRepository {
  _FakeH2hApi(this.all, {this.fail = false, this.extendingReads = 0})
    : super(Dio());

  final List<Map<String, dynamic>> all;
  final bool fail;

  /// Reads after an extend that still report `extending` (-1 = forever).
  int extendingReads;
  bool _extendAsked = false;
  final calls = <String>[];

  @override
  Future<H2hPage> loadMatchH2h(
    String id, {
    String scope = 'all',
    String? cursor,
    int limit = 20,
    bool extend = false,
  }) async {
    calls.add('$scope|${cursor ?? '-'}|$limit|${extend ? 'extend' : ''}');
    if (fail) throw DioException(requestOptions: RequestOptions());
    var extending = false;
    if (extend) {
      _extendAsked = true;
      extending = true;
    } else if (_extendAsked && extendingReads != 0) {
      extending = true;
      if (extendingReads > 0) extendingReads--;
    }
    final scoped = [
      for (final m in all)
        if (scope == 'all' || m['competitionId'] == _liga) m,
    ];
    var start = 0;
    if (cursor != null) {
      final id = cursor.split('|').last;
      start = scoped.indexWhere((m) => m['matchId'] == id) + 1;
    }
    final page = scoped.skip(start).take(limit).toList();
    final more = start + page.length < scoped.length;
    return H2hPage({
      'schemaVersion': 1,
      'meetings': page,
      'totals': _totals(scoped),
      'hasMore': more,
      'nextCursor': more
          ? '${page.last['startTime']}|${page.last['matchId']}'
          : null,
      'window': {
        'verifiedFrom': '2026-04-02',
        'canExtend': !extending,
        'extending': extending,
      },
      'teams': [
        {'id': _home, 'name': 'Equipo Casa'},
        {'id': _away, 'name': 'Equipo Visita'},
      ],
      'competitions': [
        {'id': _liga, 'name': 'Liga Larga'},
        {'id': _copa, 'name': 'Copa Larga'},
      ],
    });
  }
}

Snapshot _snapshot() => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': _at(0),
  'teams': [
    {'id': _home, 'name': 'Equipo Casa'},
    {'id': _away, 'name': 'Equipo Visita'},
  ],
  'players': <dynamic>[],
  'competitions': [
    {'id': _liga, 'name': 'Liga Larga'},
  ],
  'matches': [
    {
      'id': _target,
      'competitionId': _liga,
      'homeTeamId': _home,
      'awayTeamId': _away,
      'startTime': _at(20),
      'status': 'SCHEDULED',
      'events': <dynamic>[],
      'statistics': <dynamic>[],
    },
  ],
  'standings': <dynamic>[],
});

Future<void> _pump(
  WidgetTester tester,
  Map<String, dynamic> preview,
  FootballRepository repository,
) async {
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final data = _snapshot();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(repository)],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: HeadToHeadTab(
              preview: AsyncValue.data(MatchPreview(preview)),
              data: data,
              match: data.matches.single,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

int _rows(WidgetTester tester) => find
    .byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('h2h-match-'),
    )
    .evaluate()
    .length;

String _value(WidgetTester tester, String key) => tester
    .widgetList<Text>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(Text),
      ),
    )
    .first
    .data!;

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('27 stored meetings: 20 first, Ver más loads the rest; totals '
      'never change with paging', (tester) async {
    final all = _history(27);
    final api = _FakeH2hApi(all);
    await _pump(tester, _preview(all), api);
    expect(_rows(tester), 20);
    final wins = _value(tester, 'h2h-home-wins');
    await _tap(tester, find.byKey(const ValueKey('h2h-more')));
    // First page from the top (no cursor), what was shown + one page.
    expect(api.calls, ['all|-|40|']);
    expect(_rows(tester), 27);
    expect(find.byKey(const ValueKey('h2h-more')), findsNothing);
    expect(_value(tester, 'h2h-home-wins'), wins);
    expect(_value(tester, 'h2h-home-wins'), '${_totals(all)['homeWins']}');
  });

  testWidgets('a pair with one meeting shows it and asks for nothing more', (
    tester,
  ) async {
    final all = _history(1);
    final api = _FakeH2hApi(all);
    await _pump(tester, _preview(all), api);
    expect(_rows(tester), 1);
    expect(find.byKey(const ValueKey('h2h-more')), findsNothing);
    expect(api.calls, isEmpty);
  });

  testWidgets('Este torneo pages its own meetings', (tester) async {
    final all = _history(40); // 27 league, 13 cup
    final api = _FakeH2hApi(all);
    await _pump(tester, _preview(all), api);
    await _tap(tester, find.text('Este torneo'));
    final shown = _rows(tester);
    expect(shown, lessThan(27));
    await _tap(tester, find.byKey(const ValueKey('h2h-more')));
    expect(api.calls.single, startsWith('competition|'));
    expect(_rows(tester), 27);
    expect(find.byKey(const ValueKey('h2h-more')), findsNothing);
    expect(find.textContaining('Copa Larga'), findsNothing);
    // Back to Todos: its own list, its own paging.
    await _tap(tester, find.text('Todos'));
    expect(_rows(tester), 20);
    expect(find.byKey(const ValueKey('h2h-more')), findsOneWidget);
  });

  testWidgets('the verified window is stated; older history is asked for '
      'centrally, once', (tester) async {
    final all = _history(3);
    final api = _FakeH2hApi(all);
    await _pump(tester, _preview(all, verifiedFrom: '2026-04-02'), api);
    expect(find.text('Historial verificado desde abr 2026'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('h2h-extend')));
    expect(api.calls.single, endsWith('|extend'));
    expect(find.byKey(const ValueKey('h2h-extending')), findsOneWidget);
    expect(find.text('Cargando historial'), findsOneWidget);
    expect(find.byKey(const ValueKey('h2h-extend')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // The next re-read finds it done: fresh list, no waiting text left.
    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
    expect(api.calls, hasLength(2));
    expect(api.calls.last, 'all|-|20|');
    expect(find.byKey(const ValueKey('h2h-extending')), findsNothing);
    expect(_rows(tester), 3);
  });

  testWidgets('an extension that never lands stops re-reading and says so', (
    tester,
  ) async {
    final all = _history(3);
    final api = _FakeH2hApi(all, extendingReads: -1);
    await _pump(tester, _preview(all, verifiedFrom: '2026-04-02'), api);
    await _tap(tester, find.byKey(const ValueKey('h2h-extend')));
    for (final delay in const [15, 30, 60, 120]) {
      await tester.pump(Duration(seconds: delay));
    }
    await tester.pumpAndSettle();
    expect(api.calls, hasLength(4), reason: 'one extend + 3 bounded re-reads');
    expect(find.text('Historial pendiente'), findsOneWidget);
    expect(find.byKey(const ValueKey('h2h-extending')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('Este torneo reaches its older meetings even when the preview '
      'listed none of them', (tester) async {
    // 22 recent cup meetings, then 3 older league ones (the target's).
    final all = [
      for (var i = 1; i <= 22; i++) _meeting(i, comp: _copa),
      for (var i = 23; i <= 25; i++) _meeting(i),
    ];
    final api = _FakeH2hApi(all);
    await _pump(tester, _preview(all), api);
    await _tap(tester, find.text('Este torneo'));
    expect(find.byKey(const ValueKey('h2h-empty-competition')), findsNothing);
    await _tap(tester, find.byKey(const ValueKey('h2h-more')));
    expect(api.calls.single, 'competition|-|20|');
    expect(_rows(tester), 3);
    expect(find.byKey(const ValueKey('h2h-more')), findsNothing);
  });

  testWidgets('no window, no extension offer; nothing claims a total history', (
    tester,
  ) async {
    final all = _history(3);
    await _pump(tester, _preview(all), _FakeH2hApi(all));
    expect(find.byKey(const ValueKey('h2h-window')), findsNothing);
    expect(find.byKey(const ValueKey('h2h-extend')), findsNothing);
    expect(find.textContaining('historial completo'), findsNothing);
  });

  testWidgets('a failed page offers Reintentar, never an endless spinner', (
    tester,
  ) async {
    final all = _history(25);
    await _pump(tester, _preview(all), _FakeH2hApi(all, fail: true));
    await _tap(tester, find.byKey(const ValueKey('h2h-more')));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Reintentar'), findsOneWidget);
    expect(_rows(tester), 20);
  });

  testWidgets('each row shows date, competition, sides and score', (
    tester,
  ) async {
    final all = _history(2);
    await _pump(tester, _preview(all), _FakeH2hApi(all));
    final row = find.byKey(const ValueKey('h2h-match-fb_match_fh001'));
    expect(
      find.descendant(of: row, matching: find.textContaining('Liga Larga')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.text('Equipo Casa')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.text('Equipo Visita')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.text('1 - 0')),
      findsOneWidget,
    );
  });
}

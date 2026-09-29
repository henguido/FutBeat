import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/matches/match_preview_sections.dart';
import 'package:futbeat/shared/widgets.dart';
import 'package:go_router/go_router.dart';

// #99 v2 Cara a cara. Synthetic ids/names only.

const _home = 'fb_team_hv_home';
const _away = 'fb_team_hv_away';
const _comp = 'fb_comp_hv_liga';
const _cup = 'fb_comp_hv_copa';
const _target = 'fb_match_hv_target';

String _at(int days) =>
    DateTime.now().toUtc().add(Duration(days: days)).toIso8601String();

Map<String, dynamic> _meeting(
  String id,
  String home,
  String away,
  int hs,
  int as,
  int days, {
  String comp = _comp,
}) => {
  'matchId': id,
  'competitionId': comp,
  'startTime': _at(days),
  'status': 'VERIFIED',
  'homeTeamId': home,
  'awayTeamId': away,
  'score': {'home': hs, 'away': as},
};

Map<String, dynamic> _preview({
  String availability = 'AVAILABLE',
  List<Map<String, dynamic>>? meetings,
  Map<String, dynamic>? totals,
  Map<String, dynamic>? competitionTotals,
  Map<String, dynamic>? current,
  bool legacy = false,
}) {
  final rows =
      meetings ??
      [
        _meeting('fb_match_hv1', _home, _away, 2, 0, -10),
        _meeting('fb_match_hv2', _away, _home, 1, 1, -40, comp: _cup),
        _meeting('fb_match_hv3', _away, _home, 3, 0, -90),
      ];
  return {
    'schemaVersion': 1,
    'matchId': _target,
    'homeTeamId': _home,
    'awayTeamId': _away,
    'h2h': legacy
        ? {
            'state': rows.isEmpty ? 'none' : 'available',
            'matchIds': [for (final m in rows) m['matchId']],
          }
        : {
            'availability': availability,
            'competitionId': _comp,
            'meetings': rows,
            'totals':
                totals ??
                {'homeWins': 1, 'draws': 1, 'awayWins': 1, 'counted': 3},
            'competitionTotals':
                competitionTotals ??
                {
                  'competitionId': _comp,
                  'homeWins': 1,
                  'draws': 0,
                  'awayWins': 1,
                  'counted': 2,
                },
            'current': ?current,
          },
    'matches': legacy ? rows : <dynamic>[],
    'teams': [
      {'id': _home, 'name': 'Equipo Norte'},
      {'id': _away, 'name': 'Equipo Sur'},
    ],
    'competitions': [
      {'id': _comp, 'name': 'Liga Sintética'},
      {'id': _cup, 'name': 'Copa Sintética'},
    ],
  };
}

Snapshot _snapshot(String status) => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': _at(0),
  'teams': [
    {'id': _home, 'name': 'Equipo Norte'},
    {'id': _away, 'name': 'Equipo Sur'},
  ],
  'players': <dynamic>[],
  'competitions': [
    {'id': _comp, 'name': 'Liga Sintética'},
  ],
  'matches': [
    {
      'id': _target,
      'competitionId': _comp,
      'homeTeamId': _home,
      'awayTeamId': _away,
      'startTime': _at(2),
      'status': status,
      'events': <dynamic>[],
      'statistics': <dynamic>[],
    },
  ],
  'standings': <dynamic>[],
});

Future<void> _pump(
  WidgetTester tester,
  Map<String, dynamic> preview, {
  String status = 'SCHEDULED',
}) async {
  tester.view.physicalSize = const Size(390, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final data = _snapshot(status);
  final match = data.matches.single;
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(
          body: SingleChildScrollView(
            child: HeadToHeadTab(
              preview: AsyncValue.data(MatchPreview(preview)),
              data: data,
              match: match,
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/match/:id',
        builder: (_, state) =>
            Scaffold(body: Text('Partido ${state.pathParameters['id']}')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(child: MaterialApp.router(routerConfig: router)),
  );
  await tester.pumpAndSettle();
}

String _value(WidgetTester tester, String key) => tester
    .widgetList<Text>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(Text),
      ),
    )
    .first
    .data!;

List<int> _barFlex(WidgetTester tester) => tester
    .widgetList<Expanded>(
      find.descendant(
        of: find.byKey(const ValueKey('h2h-bar')),
        matching: find.byType(Expanded),
      ),
    )
    .map((e) => e.flex)
    .toList();

void main() {
  testWidgets('1/2. wins · draws · wins and a proportional bar', (
    tester,
  ) async {
    await _pump(
      tester,
      _preview(
        totals: {'homeWins': 1, 'draws': 2, 'awayWins': 7, 'counted': 10},
      ),
    );
    expect(_value(tester, 'h2h-home-wins'), '1');
    expect(_value(tester, 'h2h-draws'), '2');
    expect(_value(tester, 'h2h-away-wins'), '7');
    expect(find.text('victoria'), findsOneWidget);
    expect(find.text('empates'), findsOneWidget);
    expect(find.text('victorias'), findsOneWidget);
    expect(_barFlex(tester), [1, 2, 7]);
  });

  testWidgets('3. reversed historical home/away counts by team id (legacy)', (
    tester,
  ) async {
    // Home team lost 0-3 as the AWAY side and drew; legacy: counted here.
    await _pump(
      tester,
      _preview(
        legacy: true,
        meetings: [
          _meeting('fb_match_hr1', _away, _home, 3, 0, -5),
          _meeting('fb_match_hr2', _away, _home, 0, 2, -9),
          _meeting('fb_match_hr3', _home, _away, 1, 1, -20),
        ],
      ),
    );
    expect(_value(tester, 'h2h-home-wins'), '1');
    expect(_value(tester, 'h2h-draws'), '1');
    expect(_value(tester, 'h2h-away-wins'), '1');
  });

  testWidgets('4/5. a scheduled or live current match is on top, never '
      'counted', (tester) async {
    for (final (status, label) in [
      ('SCHEDULED', 'Próximo'),
      ('LIVE', 'En vivo'),
    ]) {
      await _pump(
        tester,
        _preview(
          current: {
            'matchId': _target,
            'competitionId': _comp,
            'startTime': _at(0),
            'status': status,
            'homeTeamId': _home,
            'awayTeamId': _away,
            if (status == 'LIVE') 'score': {'home': 4, 'away': 0},
          },
        ),
        status: status,
      );
      final current = find.byKey(const ValueKey('h2h-current'));
      expect(current, findsOneWidget);
      expect(
        find.descendant(of: current, matching: find.textContaining(label)),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(current).dy <
            tester
                .getTopLeft(
                  find.byKey(const ValueKey('h2h-match-fb_match_hv1')),
                )
                .dy,
        isTrue,
      );
      // Totals are the server's finals only (1 · 1 · 1), not the live 4-0.
      expect(_value(tester, 'h2h-home-wins'), '1');
    }
  });

  testWidgets('6. a final current match is listed once as a meeting', (
    tester,
  ) async {
    await _pump(
      tester,
      _preview(
        meetings: [
          _meeting(_target, _home, _away, 2, 1, -1),
          _meeting('fb_match_hv1', _home, _away, 2, 0, -10),
        ],
        totals: {'homeWins': 2, 'draws': 0, 'awayWins': 0, 'counted': 2},
      ),
      status: 'VERIFIED',
    );
    expect(find.byKey(const ValueKey('h2h-current')), findsNothing);
    expect(find.byKey(const ValueKey('h2h-match-$_target')), findsOneWidget);
    expect(_value(tester, 'h2h-home-wins'), '2');
  });

  testWidgets('7/8. Todos and Este torneo', (tester) async {
    await _pump(tester, _preview());
    expect(find.text('Todos'), findsOneWidget);
    expect(find.text('Este torneo'), findsOneWidget);
    for (final id in ['fb_match_hv1', 'fb_match_hv2', 'fb_match_hv3']) {
      expect(find.byKey(ValueKey('h2h-match-$id')), findsOneWidget);
    }
    await tester.tap(find.text('Este torneo'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('h2h-match-fb_match_hv2')), findsNothing);
    expect(
      find.byKey(const ValueKey('h2h-match-fb_match_hv1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('h2h-match-fb_match_hv3')),
      findsOneWidget,
    );
    expect(_value(tester, 'h2h-draws'), '0'); // competitionTotals
    expect(_barFlex(tester), [1, 1]);
    await tester.tap(find.text('Todos'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('h2h-match-fb_match_hv2')),
      findsOneWidget,
    );
    expect(_value(tester, 'h2h-draws'), '1');
  });

  testWidgets('9/13. pending shows a quiet skeleton, never a spinner', (
    tester,
  ) async {
    await _pump(tester, _preview(availability: 'PENDING', meetings: []));
    expect(find.byKey(const ValueKey('h2h-pending')), findsOneWidget);
    expect(find.text('Cargando historial'), findsOneWidget);
    expect(find.text('Sin enfrentamientos anteriores'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('10. confirmed empty says so, briefly', (tester) async {
    await _pump(
      tester,
      _preview(availability: 'CONFIRMED_EMPTY', meetings: []),
    );
    expect(find.text('Sin enfrentamientos anteriores'), findsOneWidget);
    expect(find.text('Cargando historial'), findsNothing);
    await _pump(tester, _preview(availability: 'UNAVAILABLE', meetings: []));
    expect(find.text('Historial no disponible'), findsOneWidget);
  });

  testWidgets('11. real names and crests of both sides', (tester) async {
    await _pump(tester, _preview());
    final summary = find.byKey(const ValueKey('h2h-summary'));
    expect(
      find.descendant(of: summary, matching: find.text('Equipo Norte')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: summary, matching: find.text('Equipo Sur')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: summary, matching: find.byType(EntityAvatar)),
      findsNWidgets(2),
    );
    expect(find.textContaining('Liga Sintética'), findsWidgets);
  });

  testWidgets('12. tapping a meeting opens that match', (tester) async {
    await _pump(tester, _preview());
    await tester.tap(find.byKey(const ValueKey('h2h-match-fb_match_hv1')));
    await tester.pumpAndSettle();
    expect(find.text('Partido fb_match_hv1'), findsOneWidget);
  });

  testWidgets('14. no assistant-like copy in any state', (tester) async {
    const banned = [
      'FutBeat irá mostrando',
      'Todavía estamos recopilando',
      'No se encontraron registros publicados',
      'Sin enfrentamientos previos registrados',
      'Últimos enfrentamientos registrados',
    ];
    for (final preview in [
      _preview(),
      _preview(availability: 'PENDING', meetings: []),
      _preview(availability: 'CONFIRMED_EMPTY', meetings: []),
      _preview(availability: 'UNAVAILABLE', meetings: []),
    ]) {
      await _pump(tester, preview);
      for (final text in banned) {
        expect(find.textContaining(text), findsNothing, reason: text);
      }
    }
  });
}

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/match_preview_sections.dart';
import 'package:futbeat/features/matches/match_screen.dart';
import 'package:go_router/go_router.dart';

// Issue #99 phase 2: recent form + head-to-head from a separate read
// (/v1/match-preview) that never blocks the Match Center, fails on its own
// and is read once per open. Everything synthetic.

const _match = 'fb_match_p2';
const _home = 'fb_team_p2_home';
const _away = 'fb_team_p2_away';
const _other = 'fb_team_p2_other';
const _longName = 'Club Atlético Extraordinariamente Largo de la Gran Ciudad';

Map<String, dynamic> _context({
  String status = 'SCHEDULED',
  bool table = true,
  bool standingsPending = false,
  List<Map<String, dynamic>> events = const [],
  bool longNames = false,
}) {
  final now = DateTime.now().toUtc();
  final kickoff = status == 'SCHEDULED'
      ? now.add(const Duration(days: 1))
      : now.subtract(const Duration(days: 3));
  return {
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': now.toIso8601String(),
    'coverage': {
      'standings': table
          ? 'available'
          : (standingsPending ? 'pending' : 'missing'),
      'standingsPending': standingsPending,
    },
    'competitions': [
      {
        'id': 'fb_comp_p2',
        'name': longNames ? 'Campeonato $_longName' : 'Liga Fase Dos',
      },
    ],
    'teams': [
      {'id': _home, 'name': longNames ? _longName : 'Local Dos'},
      {'id': _away, 'name': longNames ? '$_longName B' : 'Visita Dos'},
      {'id': _other, 'name': 'Otro Dos'},
    ],
    'players': <dynamic>[],
    'standings': [
      if (table)
        {
          'competitionId': 'fb_comp_p2',
          'season': '2026',
          'rows': [
            {
              'teamId': _other,
              'played': 5,
              'won': 5,
              'drawn': 0,
              'lost': 0,
              'gf': 9,
              'ga': 1,
              'points': 15,
            },
            {
              'teamId': _home,
              'played': 5,
              'won': 4,
              'drawn': 0,
              'lost': 1,
              'gf': 8,
              'ga': 3,
              'points': 12,
            },
            {
              'teamId': _away,
              'played': 5,
              'won': 1,
              'drawn': 2,
              'lost': 2,
              'gf': 4,
              'ga': 6,
              'points': 5,
            },
          ],
        },
    ],
    'matches': [
      {
        'id': _match,
        'competitionId': 'fb_comp_p2',
        'homeTeamId': _home,
        'awayTeamId': _away,
        'startTime': kickoff.toIso8601String(),
        'status': status,
        'season': '2026',
        if (status != 'SCHEDULED') 'score': {'home': 1, 'away': 0},
        'events': events,
        'statistics': <dynamic>[],
      },
    ],
  };
}

Map<String, dynamic> _item(
  String id,
  String home,
  String away,
  int? homeGoals,
  int? awayGoals,
  int daysAgo,
) => {
  'matchId': id,
  'competitionId': 'fb_comp_p2',
  'startTime': DateTime.now()
      .toUtc()
      .subtract(Duration(days: daysAgo))
      .toIso8601String(),
  'status': 'VERIFIED',
  'homeTeamId': home,
  'awayTeamId': away,
  'score': homeGoals == null ? null : {'home': homeGoals, 'away': awayGoals},
};

/// Synthetic legacy preview: home form includes a scoreless row before an
/// older scored result, so the client also fails closed if an older server
/// sends incomplete candidates. Away form: D, L.
/// H2H: home wins 2, draw 1, away wins 1.
Map<String, dynamic> _preview({bool h2h = true, bool longNames = false}) {
  final items = [
    _item('fb_match_f1', _home, _other, 2, 0, 5),
    _item('fb_match_f2', _other, _home, 3, 1, 10),
    _item('fb_match_f3', _home, _other, 1, 1, 15),
    _item('fb_match_f4', _other, _home, 0, 2, 20),
    _item('fb_match_f5', _home, _other, null, null, 25),
    _item('fb_match_f6', _home, _other, 5, 0, 30),
    _item('fb_match_a1', _away, _other, 0, 0, 6),
    _item('fb_match_a2', _other, _away, 2, 1, 12),
    _item('fb_match_h1', _home, _away, 2, 1, 100),
    _item('fb_match_h2', _away, _home, 0, 1, 200),
    _item('fb_match_h3', _home, _away, 1, 1, 300),
    _item('fb_match_h4', _away, _home, 3, 0, 400),
  ];
  return {
    'schemaVersion': 1,
    'matchId': _match,
    'homeTeamId': _home,
    'awayTeamId': _away,
    'form': {
      'home': {
        'state': 'available',
        'matchIds': [
          'fb_match_f1',
          'fb_match_f2',
          'fb_match_f3',
          'fb_match_f4',
          'fb_match_f5',
          'fb_match_f6',
        ],
      },
      'away': {
        'state': 'partial',
        'matchIds': ['fb_match_a1', 'fb_match_a2'],
      },
    },
    'h2h': h2h
        ? {
            'state': 'available',
            'matchIds': [
              'fb_match_h1',
              'fb_match_h2',
              'fb_match_h3',
              'fb_match_h4',
            ],
          }
        : {'state': 'none', 'matchIds': <dynamic>[]},
    'matches': items,
    'teams': [
      {'id': _home, 'name': longNames ? _longName : 'Local Dos'},
      {'id': _away, 'name': longNames ? '$_longName B' : 'Visita Dos'},
      {'id': _other, 'name': 'Otro Dos'},
    ],
    'competitions': [
      {
        'id': 'fb_comp_p2',
        'name': longNames ? 'Campeonato $_longName' : 'Liga Fase Dos',
      },
    ],
  };
}

Map<String, dynamic> _detail({bool partial = false}) => {
  'matchId': _match,
  'available': partial,
  'pending': false,
  'hydrationNeeded': false,
  'detailLevel': partial ? 'live' : 'none',
  'stadium': partial ? 'Estadio Dos' : null,
  'coverage': {
    'detail': 'missing',
    'lineup': 'missing',
    'statistics': 'missing',
    'stale': false,
  },
  'home': <String, dynamic>{},
  'away': <String, dynamic>{},
  'statistics': <dynamic>[],
  'incidents': partial
      ? [
          {
            'type': 'GOAL',
            'minute': 12,
            'label': 'Gol',
            'detail': 'Anotador Parcial',
            'side': 'home',
          },
        ]
      : <dynamic>[],
  'videos': <dynamic>[],
};

class _Server {
  _Server(this.context, {this.preview, this.detail});

  Map<String, dynamic> Function(int read) context;

  /// null = the preview read fails.
  Map<String, dynamic>? Function()? preview;
  Map<String, dynamic> Function()? detail;
  Completer<void>? previewGate;
  int contextReads = 0;
  int previewReads = 0;

  Dio dio() => Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          if (options.path == '/v1/match-context') {
            handler.resolve(
              Response(requestOptions: options, data: context(contextReads++)),
            );
            return;
          }
          if (options.path == '/v1/match-preview') {
            previewReads++;
            if (previewGate != null) await previewGate!.future;
            final data = (preview ?? _preview)();
            if (data == null) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response(requestOptions: options, statusCode: 503),
                  type: DioExceptionType.badResponse,
                ),
              );
            } else {
              handler.resolve(Response(requestOptions: options, data: data));
            }
            return;
          }
          handler.resolve(
            Response(requestOptions: options, data: (detail ?? _detail)()),
          );
        },
      ),
    );
}

Future<ProviderContainer> _open(
  WidgetTester tester,
  _Server server, {
  double width = 390,
}) async {
  tester.view.physicalSize = Size(width, 820);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final db = AppDatabase(NativeDatabase.memory());
  await tester.runAsync(() => db.customSelect('select 1').get());
  addTearDown(() => tester.runAsync(db.close));
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(ApiRepository(server.dio())),
      followsProvider.overrideWith((ref) => Stream.value({})),
      liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: MatchScreen(id: _match)),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return container;
}

Future<void> _close(WidgetTester tester, ProviderContainer container) async {
  await tester.pump(const Duration(milliseconds: 10));
  await tester.pumpWidget(const SizedBox());
  container.dispose();
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tab(WidgetTester tester, String label) async {
  final tab = find.descendant(
    of: find.byType(TabBar),
    matching: find.text(label),
  );
  await tester.ensureVisible(tab);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(tab, warnIfMissed: false);
  await _settle(tester);
}

String _selectedTab(WidgetTester tester) {
  final bar = tester.widget<TabBar>(find.byType(TabBar));
  return (bar.tabs[bar.controller!.index] as Tab).text!;
}

Future<void> _elapse(WidgetTester tester, Duration total) async {
  for (
    var t = Duration.zero;
    t < total;
    t += const Duration(milliseconds: 500)
  ) {
    await tester.pump(const Duration(milliseconds: 500));
  }
}

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    150,
    scrollable: find.byType(Scrollable).last,
  );
  await _settle(tester);
}

List<String> _chips(WidgetTester tester, String key) => [
  for (final text in tester.widgetList<Text>(
    find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text)),
  ))
    if (const {'V', 'E', 'D', '–'}.contains(text.data)) text.data!,
];

String _textIn(WidgetTester tester, String key) => tester
    .widgetList<Text>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(Text),
      ),
    )
    .map((t) => t.data)
    .join('|');

void main() {
  test('teamMatchResult: perspective by canonical id; no result without a '
      'complete score', () {
    Json m(String h, String a, int? hg, int? ag) => {
      'homeTeamId': h,
      'awayTeamId': a,
      'score': hg == null ? null : {'home': hg, 'away': ag},
    };
    expect(teamMatchResult(m('a', 'b', 2, 0), 'a'), TeamResult.win);
    expect(teamMatchResult(m('a', 'b', 2, 0), 'b'), TeamResult.loss);
    expect(teamMatchResult(m('b', 'a', 0, 2), 'a'), TeamResult.win);
    expect(teamMatchResult(m('a', 'b', 1, 1), 'b'), TeamResult.draw);
    expect(teamMatchResult(m('a', 'b', null, null), 'a'), isNull);
    expect(teamMatchResult(m('a', 'b', 1, 0), 'c'), isNull);
  });

  testWidgets('1. six stable tabs before kickoff', (tester) async {
    final container = await _open(tester, _Server((_) => _context()));
    final bar = tester.widget<TabBar>(find.byType(TabBar));
    expect(
      [for (final t in bar.tabs) (t as Tab).text],
      [
        'Previa',
        'En vivo',
        'Alineación',
        'Tabla',
        'Estadísticas',
        'Cara a cara',
      ],
    );
    expect(bar.controller!.length, 6);
    expect(bar.isScrollable, true);
    await _close(tester, container);
  });

  testWidgets('2/3. Previa shows at once while the preview loads; form '
      'appears when it arrives', (tester) async {
    final server = _Server((_) => _context())..previewGate = Completer<void>();
    final container = await _open(tester, server);
    expect(find.byKey(const ValueKey('match-hero')), findsOneWidget);
    expect(find.text('Información del partido'), findsOneWidget);
    await _scrollTo(tester, find.byKey(const ValueKey('form-loading')));
    expect(find.byKey(const ValueKey('form-loading')), findsOneWidget);
    server.previewGate!.complete();
    await _settle(tester);
    expect(find.byKey(const ValueKey('recent-form')), findsOneWidget);
    await _close(tester, container);
  });

  testWidgets('4-7. V/E/D from each side\'s perspective, oldest -> newest, '
      'at most 5', (tester) async {
    final container = await _open(tester, _Server((_) => _context()));
    await _scrollTo(tester, find.byKey(const ValueKey('recent-form')));
    // Missing score is skipped; the next real result fills the fifth chip.
    expect(_chips(tester, 'form-home'), ['V', 'V', 'E', 'D', 'V']);
    // Away newest first: D (0-0 home), L (lost 2-1 away).
    expect(_chips(tester, 'form-away'), ['D', 'E']);
    await _close(tester, container);
  });

  testWidgets(
    'form result opens its canonical match with real preview context',
    (tester) async {
      final data = Snapshot(_context());
      final match = data.match(_match)!;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: RecentFormSection(
                preview: AsyncValue.data(MatchPreview(_preview())),
                data: data,
                match: match,
              ),
            ),
          ),
          GoRoute(
            path: '/match/:id',
            builder: (_, state) {
              final id = state.pathParameters['id']!;
              final contextMatch = (state.extra as Snapshot?)?.match(id);
              return Scaffold(
                body: Text('$id:${contextMatch?.json['score']?['home']}'),
              );
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.tap(find.byKey(const ValueKey('form-match-fb_match_f1')));
      await tester.pumpAndSettle();
      expect(find.text('fb_match_f1:2'), findsOneWidget);
    },
  );

  testWidgets('form result without a canonical match ID is not a link', (
    tester,
  ) async {
    final data = Snapshot(_context());
    final preview = _preview();
    final item = _item('external/id', _home, _other, 2, 0, 5);
    preview['matches'] = [item];
    (preview['form'] as Map)['home'] = {
      'state': 'available',
      'matchIds': ['external/id'],
    };
    (preview['form'] as Map)['away'] = {
      'state': 'none',
      'matchIds': <String>[],
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecentFormSection(
            preview: AsyncValue.data(MatchPreview(preview)),
            data: data,
            match: data.match(_match)!,
          ),
        ),
      ),
    );
    expect(find.text('V'), findsOneWidget);
    final link = tester.widget<InkWell>(
      find.ancestor(of: find.text('V'), matching: find.byType(InkWell)).first,
    );
    expect(link.onTap, isNull);
  });

  testWidgets('8. no empty events card before kickoff', (tester) async {
    final container = await _open(tester, _Server((_) => _context()));
    expect(find.text('Eventos del partido'), findsNothing);
    expect(find.text('Sin eventos'), findsNothing);
    await _tab(tester, 'En vivo');
    expect(find.text('El partido aún no inicia'), findsOneWidget);
    expect(find.text('Eventos del partido'), findsNothing);
    await _close(tester, container);
  });

  testWidgets('9. real events are shown (finished match)', (tester) async {
    final container = await _open(
      tester,
      _Server(
        (_) => _context(
          status: 'VERIFIED',
          events: [
            {
              'id': 'e1',
              'type': 'GOAL',
              'minute': 30,
              'side': 'home',
              'label': 'Gol canónico',
            },
          ],
        ),
      ),
    );
    expect(_selectedTab(tester), 'Hechos');
    expect(find.text('Eventos del partido'), findsNothing);
    await _tab(tester, 'En vivo');
    expect(find.text('Eventos del partido'), findsOneWidget);
    expect(find.byType(MatchTimeline), findsOneWidget);
    await _close(tester, container);
  });

  testWidgets('10/11. mini table from the loaded standings; hidden without', (
    tester,
  ) async {
    var container = await _open(tester, _Server((_) => _context()));
    await _scrollTo(tester, find.byKey(const ValueKey('standings-snapshot')));
    expect(find.text('Posición en la tabla'), findsOneWidget);
    final text = _textIn(tester, 'standings-snapshot');
    expect(text, contains('#2'));
    expect(text, contains('12 pts'));
    expect(text, contains('#3'));
    expect(text, contains('5 pts'));
    await _close(tester, container);

    container = await _open(tester, _Server((_) => _context(table: false)));
    await _scrollTo(tester, find.byKey(const ValueKey('recent-form')));
    expect(find.byKey(const ValueKey('standings-snapshot')), findsNothing);
    await _close(tester, container);
  });

  testWidgets('mini table never turns missing points into zero', (
    tester,
  ) async {
    final context = _context();
    final rows = ((context['standings'] as List).first['rows'] as List);
    (rows[1] as Map).remove('points');
    final container = await _open(tester, _Server((_) => context));
    await _scrollTo(tester, find.byKey(const ValueKey('standings-snapshot')));
    final text = _textIn(tester, 'standings-snapshot');
    expect(text, contains('Local Dos'));
    expect(text, contains('5 pts'));
    expect(text, isNot(contains('0 pts')));
    await _close(tester, container);
  });

  testWidgets('mini table keeps real zero but hides invalid points', (
    tester,
  ) async {
    final context = _context();
    final rows = ((context['standings'] as List).first['rows'] as List);
    (rows[1] as Map)['points'] = 0;
    (rows[2] as Map)['points'] = -1;
    final container = await _open(tester, _Server((_) => context));
    await _scrollTo(tester, find.byKey(const ValueKey('standings-snapshot')));
    final text = _textIn(tester, 'standings-snapshot');
    expect(text, contains('0 pts'));
    expect(text, isNot(contains('-1 pts')));
    await _close(tester, container);
  });

  testWidgets('10. finished match: labelled as the season table', (
    tester,
  ) async {
    final container = await _open(
      tester,
      _Server((_) => _context(status: 'VERIFIED')),
    );
    await _scrollTo(tester, find.byKey(const ValueKey('standings-snapshot')));
    expect(find.text('Tabla de la temporada'), findsOneWidget);
    expect(find.text('Posición en la tabla'), findsNothing);
    await _close(tester, container);
  });

  testWidgets('12/13. Cara a cara: summary counts and the meetings', (
    tester,
  ) async {
    final container = await _open(tester, _Server((_) => _context()));
    await _tab(tester, 'Cara a cara');
    // Real names, both sides, and the proportional bar (#99 v2).
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('h2h-summary')),
        matching: find.text('Local Dos'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('h2h-bar')), findsOneWidget);
    expect(_textIn(tester, 'h2h-home-wins'), contains('2'));
    expect(_textIn(tester, 'h2h-draws'), contains('1'));
    expect(_textIn(tester, 'h2h-away-wins'), contains('1'));
    for (final id in ['fb_match_h1', 'fb_match_h2', 'fb_match_h3']) {
      await tester.scrollUntilVisible(
        find.byKey(ValueKey('h2h-match-$id')),
        150,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.byKey(ValueKey('h2h-match-$id')), findsOneWidget);
    }
    await _close(tester, container);
  });

  testWidgets('14/15. no local H2H (legacy answer) is pending, never an '
      'empty history, never "nunca"', (tester) async {
    final container = await _open(
      tester,
      _Server((_) => _context(), preview: () => _preview(h2h: false)),
    );
    await _tab(tester, 'Cara a cara');
    // #99 v2: a cache miss is not "no previous meetings".
    expect(find.text('Cargando historial'), findsOneWidget);
    expect(find.text('Sin enfrentamientos previos registrados'), findsNothing);
    expect(find.text('Sin enfrentamientos anteriores'), findsNothing);
    expect(find.textContaining('nunca', findRichText: true), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await _close(tester, container);
  });

  testWidgets('16. a failed preview never breaks the Match Center and is not '
      'retried automatically', (tester) async {
    final server = _Server((_) => _context(), preview: () => null);
    final container = await _open(tester, server);
    await _settle(tester);
    expect(find.text('Información del partido'), findsOneWidget);
    expect(find.text('Forma reciente'), findsNothing);
    expect(find.byKey(const ValueKey('recent-form')), findsNothing);
    await _tab(tester, 'Cara a cara');
    expect(find.text('Cara a cara no disponible'), findsOneWidget);
    await _elapse(tester, const Duration(seconds: 30));
    expect(server.previewReads, 1, reason: 'no automatic retry');
    await _tab(tester, 'Tabla');
    expect(find.text('Clasificación'), findsOneWidget);
    await _close(tester, container);
  });

  testWidgets('form hides missing coverage instead of claiming no matches', (
    tester,
  ) async {
    final preview = _preview();
    preview['form'] = {
      'home': {
        'state': 'none',
        'matchIds': ['fb_match_f5'],
      },
      'away': {'state': 'none', 'matchIds': <String>[]},
    };
    final container = await _open(
      tester,
      _Server((_) => _context(), preview: () => preview),
    );
    await _settle(tester);
    expect(find.text('Forma reciente'), findsNothing);
    expect(find.byKey(const ValueKey('recent-form')), findsNothing);
    expect(find.text('Sin partidos recientes'), findsNothing);
    await _close(tester, container);
  });

  testWidgets('form shows only the side with a real scored result', (
    tester,
  ) async {
    final preview = _preview();
    preview['form'] = {
      'home': {
        'state': 'partial',
        'matchIds': ['fb_match_f1'],
      },
      'away': {'state': 'none', 'matchIds': <String>[]},
    };
    final container = await _open(
      tester,
      _Server((_) => _context(), preview: () => preview),
      width: 320,
    );
    await _scrollTo(tester, find.byKey(const ValueKey('recent-form')));
    expect(find.text('Forma reciente'), findsOneWidget);
    expect(find.byKey(const ValueKey('form-home')), findsOneWidget);
    expect(find.byKey(const ValueKey('form-away')), findsNothing);
    expect(_chips(tester, 'form-home'), ['V']);
    expect(tester.takeException(), isNull);
    await _close(tester, container);
  });

  testWidgets('form rejects incomplete, negative and fractional scores', (
    tester,
  ) async {
    final preview = _preview();
    final matches = preview['matches'] as List;
    for (final item in matches) {
      if (item is! Map<String, dynamic>) continue;
      switch (item['matchId']) {
        case 'fb_match_f1':
          item['score'] = {'home': 1, 'away': null};
        case 'fb_match_f2':
          item['score'] = {'home': -1, 'away': 0};
        case 'fb_match_f3':
          item['score'] = {'home': 1.5, 'away': 1};
      }
    }
    preview['form'] = {
      'home': {
        'state': 'partial',
        'matchIds': ['fb_match_f1', 'fb_match_f2', 'fb_match_f3'],
      },
      'away': {'state': 'none', 'matchIds': <String>[]},
    };
    final container = await _open(
      tester,
      _Server((_) => _context(), preview: () => preview),
    );
    await _settle(tester);
    expect(find.text('Forma reciente'), findsNothing);
    expect(find.byKey(const ValueKey('recent-form')), findsNothing);
    await _close(tester, container);
  });

  testWidgets('17/18. tab switches and standings refreshes never re-read the '
      'preview', (tester) async {
    final server = _Server(
      (i) =>
          i == 0 ? _context(table: false, standingsPending: true) : _context(),
    );
    final container = await _open(tester, server);
    for (final tab in [
      'Cara a cara',
      'Tabla',
      'Previa',
      'Estadísticas',
      'Cara a cara',
    ]) {
      await _tab(tester, tab);
    }
    await _elapse(
      tester,
      standingsRetryDelays.first + const Duration(seconds: 1),
    );
    expect(server.contextReads, 2, reason: 'standings refreshed');
    await _tab(tester, 'Tabla');
    await _tab(tester, 'Cara a cara');
    expect(server.previewReads, 1);
    await _close(tester, container);
  });

  testWidgets('19. #101 partial detail stays visible in Hechos', (
    tester,
  ) async {
    final container = await _open(
      tester,
      _Server(
        (_) => _context(status: 'VERIFIED'),
        detail: () => _detail(partial: true),
      ),
    );
    // Hechos keeps the general info; the chronology lives only in En vivo.
    expect(find.text('Estadio Dos'), findsWidgets);
    expect(find.text('Anotador Parcial'), findsNothing);
    await _tab(tester, 'En vivo');
    expect(find.text('Anotador Parcial'), findsWidgets);
    await _close(tester, container);
  });

  for (final width in [360.0, 390.0]) {
    testWidgets('20/21. ${width.toInt()} px with long names: no overflow', (
      tester,
    ) async {
      final container = await _open(
        tester,
        _Server(
          (_) => _context(longNames: true),
          preview: () => _preview(longNames: true),
        ),
        width: width,
      );
      await _scrollTo(tester, find.byKey(const ValueKey('recent-form')));
      expect(tester.takeException(), isNull);
      await _tab(tester, 'Cara a cara');
      expect(tester.takeException(), isNull);
      await _close(tester, container);
    });
  }

  testWidgets('22. each tab keeps its scroll position', (tester) async {
    final container = await _open(tester, _Server((_) => _context()));
    await _scrollTo(tester, find.byKey(const ValueKey('recent-form')));
    final before = tester.getTopLeft(find.byKey(const ValueKey('recent-form')));
    await _tab(tester, 'Cara a cara');
    await _tab(tester, 'Previa');
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('recent-form'))),
      before,
    );
    await _close(tester, container);
  });

  // #120: the canonical context is read once per open; a LIVE match whose live
  // data went silent must re-read it (bounded) so a server final replaces it.
  Map<String, dynamic> liveContext(Duration silentFor) {
    final context = _context(status: 'LIVE');
    final match = (context['matches'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((m) => m['id'] == _match);
    match['minute'] = 90;
    match['liveChangedAt'] = DateTime.now()
        .toUtc()
        .subtract(silentFor)
        .toIso8601String();
    return context;
  }

  testWidgets('#120 silent LIVE re-reads the context and shows the final', (
    tester,
  ) async {
    final server = _Server(
      (i) => i == 0
          ? liveContext(const Duration(minutes: 20))
          : _context(status: 'FINISHED_PENDING_VERIFICATION'),
    );
    final container = await _open(tester, server);
    expect(server.contextReads, 1);
    // The match status ("90′ · EN VIVO"), not the permanent "En vivo" tab.
    final liveStatus = find.textContaining(
      RegExp('′ · en vivo', caseSensitive: false),
    );
    expect(liveStatus, findsWidgets);
    await _elapse(
      tester,
      staleLiveRefreshDelays.first + const Duration(seconds: 1),
    );
    await _settle(tester);
    expect(server.contextReads, 2);
    expect(liveStatus, findsNothing);
    expect(
      find.descendant(of: find.byType(TabBar), matching: find.text('En vivo')),
      findsOneWidget,
      reason: 'the tab itself stays',
    );
    await _elapse(tester, const Duration(minutes: 10));
    expect(server.contextReads, 2, reason: 'final settles: no more reads');
    await _close(tester, container);
  });

  testWidgets('#120 fresh LIVE is not re-read; silent LIVE stops after the '
      'bounded schedule', (tester) async {
    final fresh = _Server((_) => liveContext(const Duration(minutes: 1)));
    var container = await _open(tester, fresh);
    await _elapse(tester, const Duration(seconds: 40));
    expect(fresh.contextReads, 1);
    await _close(tester, container);

    final silent = _Server((_) => liveContext(const Duration(minutes: 20)));
    container = await _open(tester, silent);
    await _elapse(tester, const Duration(minutes: 12));
    expect(silent.contextReads, 1 + staleLiveRefreshDelays.length);
    await _close(tester, container);
  });
}

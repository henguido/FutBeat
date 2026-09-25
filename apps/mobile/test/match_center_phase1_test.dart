import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/theme.dart';
import 'package:futbeat/features/matches/match_screen.dart';

// Issue #99 phase 1: premium header, Previa tab, Resumida/Completa standings
// with the selected sides highlighted and real in-play evidence. UI only:
// no new requests. Everything synthetic.

const _match = 'fb_match_p1';
const _home = 'fb_team_p1_home';
const _away = 'fb_team_p1_away';
const _liveA = 'fb_team_p1_live_a';
const _liveB = 'fb_team_p1_live_b';
const _lateA = 'fb_team_p1_late_a';
const _lateB = 'fb_team_p1_late_b';
const _longName =
    'Club Deportivo Extraordinariamente Largo de la Ciudad Capital';

Map<String, dynamic> _row(String team, int points, int gf, int ga) => {
  'teamId': team,
  'played': 5,
  'won': points ~/ 3,
  'drawn': points % 3,
  'lost': 5 - points ~/ 3 - points % 3,
  'gf': gf,
  'ga': ga,
  'points': points,
};

Map<String, dynamic> _context({
  String status = 'FINISHED_PENDING_VERIFICATION',
  bool table = true,
  bool standingsPending = false,
  bool standingsStale = false,
  String? standingsState,
  bool otherLive = true,
  DateTime? start,
}) {
  final now = DateTime.now().toUtc();
  final kickoff =
      start ??
      (status == 'SCHEDULED'
          ? now.add(const Duration(days: 1))
          : now.subtract(const Duration(minutes: 70)));
  Map<String, dynamic> match(
    String id,
    String home,
    String away,
    String status,
    DateTime start, {
    bool score = true,
  }) => {
    'id': id,
    'competitionId': 'fb_comp_p1',
    'homeTeamId': home,
    'awayTeamId': away,
    'startTime': start.toIso8601String(),
    'status': status,
    'season': '2026',
    if (score) 'score': {'home': 2, 'away': 1},
    if (status == 'LIVE') 'minute': 63,
    'events': <dynamic>[],
    'statistics': <dynamic>[],
  };
  return {
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': now.toIso8601String(),
    'coverage': {
      'standings':
          standingsState ??
          (table ? 'available' : (standingsPending ? 'pending' : 'missing')),
      'standingsPending': standingsPending,
      'standingsStale': standingsStale,
    },
    'competitions': [
      {'id': 'fb_comp_p1', 'name': 'Liga Fase Uno'},
    ],
    'teams': [
      {'id': _home, 'name': 'Local Uno'},
      {'id': _away, 'name': 'Visita Uno'},
      {'id': _liveA, 'name': _longName},
      {'id': _liveB, 'name': 'Rival En Juego'},
      {'id': _lateA, 'name': 'Atrasado A'},
      {'id': _lateB, 'name': 'Atrasado B'},
    ],
    'players': <dynamic>[],
    'standings': [
      if (table)
        {
          'competitionId': 'fb_comp_p1',
          'season': '2026',
          'rows': [
            _row(_liveA, 13, 11, 4),
            _row(_home, 12, 9, 3),
            _row(_lateA, 9, 7, 6),
            _row(_away, 7, 5, 6),
            _row(_liveB, 4, 3, 8),
            _row(_lateB, 1, 2, 10),
          ],
        },
    ],
    'matches': [
      match(
        _match,
        _home,
        _away,
        status,
        kickoff,
        score: status != 'SCHEDULED',
      ),
      // Another fixture of the same competition really in play.
      match(
        'fb_match_p1_live',
        _liveA,
        _liveB,
        otherLive ? 'LIVE' : 'SCHEDULED',
        now.subtract(const Duration(minutes: 30)),
      ),
      // Kickoff passed but no live evidence: never shown as live.
      match(
        'fb_match_p1_late',
        _lateA,
        _lateB,
        'SCHEDULED',
        now.subtract(const Duration(minutes: 20)),
        score: false,
      ),
    ],
  };
}

Map<String, dynamic> _detail({bool partial = false}) => {
  'matchId': _match,
  'available': true,
  'pending': false,
  'hydrationNeeded': false,
  'detailLevel': partial ? 'live' : 'full',
  'stadium': 'Estadio Fase Uno',
  'referee': 'Árbitro Uno',
  'round': '5',
  'coverage': {
    'detail': partial ? 'missing' : 'available',
    'lineup': 'missing',
    'statistics': 'missing',
    'stale': false,
  },
  'home': <String, dynamic>{},
  'away': <String, dynamic>{},
  'statistics': <dynamic>[],
  'incidents': [
    {
      'type': 'GOAL',
      'minute': 12,
      'label': 'Gol',
      'detail': 'Anotador Parcial',
      'side': 'home',
    },
  ],
  'videos': <dynamic>[],
};

class _Server {
  _Server(this.context, {this.detail});

  Map<String, dynamic> Function(int read) context;
  Map<String, dynamic> Function(int read)? detail;
  int contextReads = 0;
  int detailReads = 0;

  Dio dio() => Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/v1/match-context') {
            handler.resolve(
              Response(requestOptions: options, data: context(contextReads++)),
            );
            return;
          }
          final data = (detail ?? (_) => _detail())(detailReads++);
          handler.resolve(Response(requestOptions: options, data: data));
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

Future<void> _elapse(WidgetTester tester, Duration total) async {
  for (
    var t = Duration.zero;
    t < total;
    t += const Duration(milliseconds: 500)
  ) {
    await tester.pump(const Duration(milliseconds: 500));
  }
}

List<String> _tabLabels(WidgetTester tester) => [
  for (final tab in tester.widget<TabBar>(find.byType(TabBar)).tabs)
    (tab as Tab).text!,
];

String _selectedTab(WidgetTester tester) {
  final bar = tester.widget<TabBar>(find.byType(TabBar));
  return (bar.tabs[bar.controller!.index] as Tab).text!;
}

Finder _inTable(String key, Finder matching) =>
    find.descendant(of: find.byKey(ValueKey(key)), matching: matching);

/// The row container's left accent (null = no highlight).
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

bool _live(WidgetTester tester, String teamId) => tester.any(
  find.descendant(
    of: find.byKey(ValueKey('standings-row-$teamId')),
    matching: find.byKey(const ValueKey('standings-live')),
  ),
);

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    120,
    scrollable: find.byType(Scrollable).last,
  );
  await _settle(tester);
}

void main() {
  testWidgets('1. tabs are Previa / Estadísticas / Alineación / Tabla', (
    tester,
  ) async {
    final container = await _open(tester, _Server((_) => _context()));
    expect(_tabLabels(tester), [
      'Previa',
      'Estadísticas',
      'Alineación',
      'Tabla',
    ]);
    expect(find.text('Resumen'), findsNothing);
    await _close(tester, container);
  });

  testWidgets('2. the TabController is the same instance across refreshes', (
    tester,
  ) async {
    final server = _Server(
      (i) =>
          i == 0 ? _context(table: false, standingsPending: true) : _context(),
    );
    final container = await _open(tester, server);
    await _tab(tester, 'Tabla');
    final controller = tester.widget<TabBar>(find.byType(TabBar)).controller;
    await _elapse(
      tester,
      standingsRetryDelays.first + const Duration(seconds: 1),
    );
    expect(server.contextReads, 2);
    expect(find.text('Clasificación'), findsOneWidget);
    final bar = tester.widget<TabBar>(find.byType(TabBar));
    expect(bar.controller, same(controller));
    expect(_selectedTab(tester), 'Tabla');
    await _close(tester, container);
  });

  testWidgets('3-7. Resumida by default (Pos/Equipo/PJ/DG/Pts); Completa adds '
      'G/E/P/GF/GC; switching is local (no request)', (tester) async {
    final server = _Server((_) => _context());
    final container = await _open(tester, server);
    await _tab(tester, 'Tabla');
    expect(find.byKey(const ValueKey('standings-compact')), findsOneWidget);
    expect(find.byKey(const ValueKey('standings-full')), findsNothing);
    for (final label in ['Pos', 'Equipo', 'PJ', 'DG', 'Pts']) {
      expect(_inTable('standings-compact', find.text(label)), findsOneWidget);
    }
    for (final label in ['G', 'E', 'P', 'GF', 'GC']) {
      expect(_inTable('standings-compact', find.text(label)), findsNothing);
    }
    // Signed goal difference, emphasized points.
    expect(_inTable('standings-compact', find.text('+7')), findsOneWidget);
    final reads = (server.contextReads, server.detailReads);
    await tester.tap(find.byKey(const ValueKey('standings-view-full')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('standings-full')), findsOneWidget);
    expect(find.byKey(const ValueKey('standings-compact')), findsNothing);
    for (final label in [
      'Pos',
      'Equipo',
      'PJ',
      'G',
      'E',
      'P',
      'GF',
      'GC',
      'DG',
      'Pts',
    ]) {
      expect(_inTable('standings-full', find.text(label)), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('standings-view-compact')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('standings-compact')), findsOneWidget);
    expect(
      (server.contextReads, server.detailReads),
      reads,
      reason: 'the view switch never makes a request',
    );
    expect(tester.takeException(), isNull);
    await _close(tester, container);
  });

  testWidgets('8-10. home and away rows highlighted with their side colors; '
      'other teams are not', (tester) async {
    final container = await _open(tester, _Server((_) => _context()));
    await _tab(tester, 'Tabla');
    expect(_accent(tester, _home), lime);
    expect(_accent(tester, _away), awaySideColor);
    expect(_accent(tester, _liveA), isNull);
    expect(_accent(tester, _lateA), isNull);
    // Also in the full view.
    await tester.tap(find.byKey(const ValueKey('standings-view-full')));
    await _settle(tester);
    expect(_accent(tester, _home), lime);
    expect(_accent(tester, _away), awaySideColor);
    await _close(tester, container);
  });

  testWidgets('11-13. EN VIVO only from real in-play status; never from '
      'kickoff time', (tester) async {
    final container = await _open(tester, _Server((_) => _context()));
    await _tab(tester, 'Tabla');
    expect(_live(tester, _liveA), true);
    expect(_live(tester, _liveB), true);
    // Kickoff 20 minutes ago but still SCHEDULED: no live marker.
    expect(_live(tester, _lateA), false);
    expect(_live(tester, _lateB), false);
    // The selected match is finished: highlighted, not live.
    expect(_live(tester, _home), false);
    await _close(tester, container);
  });

  testWidgets('11. a LIVE selected match: highlight and live marker together', (
    tester,
  ) async {
    final container = await _open(
      tester,
      _Server((_) => _context(status: 'LIVE', otherLive: false)),
    );
    await _tab(tester, 'Tabla');
    expect(_accent(tester, _home), lime);
    expect(_live(tester, _home), true);
    expect(_live(tester, _away), true);
    expect(_live(tester, _liveA), false, reason: 'its match is scheduled now');
    await _close(tester, container);
  });

  testWidgets('14. pending standings keep the loading state', (tester) async {
    final container = await _open(
      tester,
      _Server((_) => _context(table: false, standingsPending: true)),
    );
    await _tab(tester, 'Tabla');
    expect(find.text('Cargando tabla…'), findsOneWidget);
    expect(find.byKey(const ValueKey('standings-view-full')), findsNothing);
    await _elapse(tester, const Duration(minutes: 8));
    await _close(tester, container);
  });

  testWidgets('15. stale + pending keeps the table (and the switch) visible', (
    tester,
  ) async {
    final container = await _open(
      tester,
      _Server(
        (i) => i == 0
            ? _context(standingsPending: true, standingsStale: true)
            : _context(),
      ),
    );
    await _tab(tester, 'Tabla');
    expect(find.byKey(const ValueKey('standings-updating')), findsOneWidget);
    expect(find.byKey(const ValueKey('standings-compact')), findsOneWidget);
    expect(find.byKey(const ValueKey('standings-view-full')), findsOneWidget);
    await _elapse(tester, const Duration(seconds: 10));
    expect(find.byKey(const ValueKey('standings-compact')), findsOneWidget);
    await _close(tester, container);
  });

  testWidgets('16. unavailable keeps "Sin tabla disponible" (no switch)', (
    tester,
  ) async {
    final container = await _open(
      tester,
      _Server((_) => _context(table: false, standingsState: 'unavailable')),
    );
    await _tab(tester, 'Tabla');
    expect(find.text('Sin tabla disponible'), findsOneWidget);
    expect(find.byKey(const ValueKey('standings-view-compact')), findsNothing);
    await _close(tester, container);
  });

  for (final width in [360.0, 390.0, 430.0]) {
    testWidgets('17/18. ${width.toInt()} px: Resumida fits without horizontal '
        'scroll, long names ellipsize, header fits', (tester) async {
      final container = await _open(
        tester,
        _Server((_) => _context()),
        width: width,
      );
      expect(tester.takeException(), isNull, reason: 'header');
      await _tab(tester, 'Tabla');
      expect(tester.takeException(), isNull);
      final table = find.byKey(const ValueKey('standings-compact'));
      expect(
        find.ancestor(of: table, matching: find.byType(SingleChildScrollView)),
        findsNothing,
        reason: 'no horizontal scroll in Resumida',
      );
      expect(tester.getSize(table).width, lessThanOrEqualTo(width));
      final name = tester.widget<Text>(
        find.byKey(const ValueKey('standings-name-$_liveA')),
      );
      expect(name.maxLines, 1);
      expect(name.overflow, TextOverflow.ellipsis);
      final pts = _inTable('standings-compact', find.text('13'));
      expect(tester.getRect(pts).right, lessThanOrEqualTo(width));
      // The full view scrolls horizontally instead of overflowing.
      await tester.tap(find.byKey(const ValueKey('standings-view-full')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      await _close(tester, container);
    });
  }

  testWidgets('19. header: scheduled match shows kickoff and PROGRAMADO', (
    tester,
  ) async {
    final container = await _open(
      tester,
      _Server((_) => _context(status: 'SCHEDULED')),
      width: 360,
    );
    expect(find.byKey(const ValueKey('match-hero')), findsOneWidget);
    expect(find.text('PROGRAMADO'), findsOneWidget);
    expect(find.text('2 - 1'), findsNothing);
    expect(find.text('Local Uno'), findsWidgets);
    expect(find.text('Visita Uno'), findsWidgets);
    expect(find.text('Liga Fase Uno · Jornada 5'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _close(tester, container);
  });

  testWidgets('20. header: LIVE match shows score and minute', (tester) async {
    final container = await _open(
      tester,
      _Server((_) => _context(status: 'LIVE')),
      width: 360,
    );
    expect(find.text('2 - 1'), findsOneWidget);
    expect(find.text('63′ · EN VIVO'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _close(tester, container);
  });

  testWidgets('21. header: finished match shows result, date and stadium', (
    tester,
  ) async {
    final container = await _open(
      tester,
      _Server((_) => _context()),
      width: 360,
    );
    expect(find.text('2 - 1'), findsOneWidget);
    expect(find.text('FINALIZADO'), findsOneWidget);
    expect(find.text('Estadio Fase Uno'), findsWidgets);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('match-hero')),
        matching: find.byIcon(Icons.calendar_today_rounded),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await _close(tester, container);
  });

  testWidgets('22. #101 partial detail stays visible in Previa', (
    tester,
  ) async {
    final container = await _open(
      tester,
      _Server((_) => _context(), detail: (_) => _detail(partial: true)),
    );
    expect(_selectedTab(tester), 'Previa');
    expect(find.text('Anotador Parcial'), findsWidgets);
    expect(find.text('Estadio Fase Uno'), findsWidgets);
    await _scrollTo(tester, find.text('Información del partido'));
    expect(find.text('Información del partido'), findsOneWidget);
    await _close(tester, container);
  });
}

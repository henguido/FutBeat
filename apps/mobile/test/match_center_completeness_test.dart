import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/match_screen.dart';

// Generic Match Center completeness on the phone: data that arrives after
// the screen opened appears in place (no leave/re-enter), the tab is kept,
// refreshes never flash or lose data, and retries always end.

const _match = 'fb_match_mc';

Map<String, dynamic> _context({
  bool standings = false,
  bool standingsPending = false,
}) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-09-01T21:00:00Z',
  'coverage': {
    'partial': false,
    'standings': standings
        ? 'available'
        : (standingsPending ? 'pending' : 'missing'),
    'standingsPending': standingsPending,
  },
  'competitions': [
    {'id': 'fb_comp_mc', 'name': 'Liga Sintética'},
  ],
  'teams': [
    {'id': 'fb_team_mc_h', 'name': 'Local Sintético'},
    {'id': 'fb_team_mc_a', 'name': 'Visita Sintética'},
  ],
  'players': <dynamic>[],
  'standings': [
    if (standings)
      {
        'competitionId': 'fb_comp_mc',
        'season': '2026-2027',
        'rows': [
          {
            'teamId': 'fb_team_mc_h',
            'played': 3,
            'won': 3,
            'drawn': 0,
            'lost': 0,
            'gf': 6,
            'ga': 1,
            'points': 9,
          },
          {
            'teamId': 'fb_team_mc_a',
            'played': 3,
            'won': 0,
            'drawn': 0,
            'lost': 3,
            'gf': 1,
            'ga': 6,
            'points': 0,
          },
        ],
      },
  ],
  'matches': [
    {
      'id': _match,
      'competitionId': 'fb_comp_mc',
      'homeTeamId': 'fb_team_mc_h',
      'awayTeamId': 'fb_team_mc_a',
      'startTime': '2026-09-01T18:00:00Z',
      'status': 'VERIFIED',
      'season': '2026/2027',
      'score': {'home': 1, 'away': 0},
      'events': <dynamic>[],
      'statistics': <dynamic>[],
    },
  ],
};

Map<String, dynamic> _detail({
  bool lineup = false,
  bool stats = false,
  bool pending = false,
}) => {
  'matchId': _match,
  'available': true,
  'pending': pending,
  'detailLevel': 'full',
  'coverage': {
    'detail': 'available',
    'lineup': lineup ? 'available' : (pending ? 'pending' : 'missing'),
    'statistics': stats ? 'available' : (pending ? 'pending' : 'missing'),
    'stale': false,
  },
  'home': lineup
      ? {
          'formation': '4-4-2',
          'starters': [
            {
              'id': 'p1',
              'canonicalId': 'fb_player_mc1',
              'name': 'Arquero Sintético',
              'number': '1',
            },
          ],
        }
      : <String, dynamic>{},
  'away': <String, dynamic>{},
  'statistics': stats
      ? [
          {'label': 'Shots on Goal', 'home': 5, 'away': 2},
        ]
      : <dynamic>[],
  'incidents': <dynamic>[],
  'videos': <dynamic>[],
};

class _Server {
  _Server({required this.detail, required this.context});
  Map<String, dynamic>? Function(int read) detail;
  Map<String, dynamic> Function(int read) context;
  int detailReads = 0;
  int contextReads = 0;

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
          final data = detail(detailReads++);
          if (data == null) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
              ),
            );
          } else {
            handler.resolve(Response(requestOptions: options, data: data));
          }
        },
      ),
    );
}

Future<ProviderContainer> _open(
  WidgetTester tester,
  _Server server, {
  double width = 360,
}) async {
  tester.view.physicalSize = Size(width, 780);
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

Future<void> _tab(WidgetTester tester, String label) async {
  final tab = find.descendant(
    of: find.byType(TabBar),
    matching: find.text(label),
  );
  await tester.ensureVisible(tab);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(tab, warnIfMissed: false);
  // Explicit pumps: the refreshing indicator animates while data is pending.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
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

String _selectedTab(WidgetTester tester) {
  final bar = tester.widget<TabBar>(find.byType(TabBar));
  return (bar.tabs[bar.controller!.index] as Tab).text!;
}

void main() {
  testWidgets('21. lineup that arrives later appears in place; tab kept', (
    tester,
  ) async {
    final server = _Server(
      // Missing at first (pending), available from the 2nd refresh on.
      detail: (i) => i < 2 ? _detail(pending: true) : _detail(lineup: true),
      context: (_) => _context(),
    );
    final container = await _open(tester, server);
    await _tab(tester, 'Alineación');
    expect(find.text('Cargando alineaciones…'), findsOneWidget);
    expect(find.byKey(const ValueKey('match-refreshing')), findsOneWidget);
    await _elapse(tester, const Duration(seconds: 20));
    expect(find.text('Cargando alineaciones…'), findsNothing);
    expect(find.text('AS'), findsWidgets); // starter on the pitch (initials)
    expect(_selectedTab(tester), 'Alineación');
    expect(find.byKey(const ValueKey('match-refreshing')), findsNothing);
    await _close(tester, container);
  });

  testWidgets('22. statistics that arrive later appear in place', (
    tester,
  ) async {
    final server = _Server(
      detail: (i) => i < 2
          ? _detail(lineup: true, pending: true)
          : _detail(lineup: true, stats: true),
      context: (_) => _context(),
    );
    final container = await _open(tester, server);
    await _tab(tester, 'Estadísticas');
    expect(find.text('Cargando estadísticas…'), findsOneWidget);
    await _elapse(tester, const Duration(seconds: 20));
    expect(find.text('Tiros a puerta'), findsWidgets);
    expect(find.text('Sin estadísticas'), findsNothing);
    await _close(tester, container);
  });

  testWidgets(
    '23. standings that arrive later add the Tabla tab; current tab kept',
    (tester) async {
      final server = _Server(
        detail: (_) => _detail(lineup: true, stats: true),
        context: (i) => i == 0
            ? _context(standingsPending: true)
            : _context(standings: true),
      );
      final container = await _open(tester, server);
      expect(find.text('Tabla'), findsNothing);
      await _tab(tester, 'Alineación');
      await _elapse(
        tester,
        standingsRetryDelays.first + const Duration(seconds: 2),
      );
      expect(find.text('Tabla'), findsOneWidget);
      expect(_selectedTab(tester), 'Alineación');
      expect(
        server.contextReads,
        2,
        reason: 'stops once standings are available',
      );
      await _elapse(tester, const Duration(minutes: 2));
      expect(server.contextReads, 2);
      await _close(tester, container);
    },
  );

  testWidgets('a failed refresh never erases a lineup already on screen', (
    tester,
  ) async {
    final server = _Server(
      detail: (i) => i == 0 ? _detail(lineup: true, pending: true) : null,
      context: (_) => _context(),
    );
    final container = await _open(tester, server);
    await _tab(tester, 'Alineación');
    expect(find.text('AS'), findsWidgets);
    for (var step = 0; step < 150; step++) {
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.text('AS'),
        findsWidgets,
        reason: 'no flash/loss at step $step',
      );
      expect(find.text('Sin alineaciones'), findsNothing);
    }
    await _close(tester, container);
  });

  testWidgets(
    '28. pending that never resolves stops after the bounded schedule',
    (tester) async {
      final server = _Server(
        detail: (_) => _detail(pending: true),
        context: (_) => _context(standingsPending: true),
      );
      final container = await _open(tester, server);
      await _elapse(tester, const Duration(minutes: 3));
      final detailReads = server.detailReads;
      final contextReads = server.contextReads;
      expect(detailReads, lessThanOrEqualTo(6));
      expect(contextReads, 1 + standingsRetryDelays.length);
      await _tab(tester, 'Alineación');
      expect(find.text('Sin alineaciones'), findsOneWidget);
      expect(find.byKey(const ValueKey('match-refreshing')), findsNothing);
      await _elapse(tester, const Duration(minutes: 2));
      expect(server.detailReads, detailReads);
      expect(server.contextReads, contextReads);
      await _close(tester, container);
    },
  );

  for (final width in [320.0, 360.0]) {
    testWidgets(
      '27. refreshing state fits ${width.toInt()}px without overflow',
      (tester) async {
        final server = _Server(
          detail: (_) => _detail(pending: true),
          context: (_) => _context(standingsPending: true),
        );
        final container = await _open(tester, server, width: width);
        for (final tab in ['Estadísticas', 'Alineación', 'Resumen']) {
          await _tab(tester, tab);
          expect(tester.takeException(), isNull);
        }
        await _elapse(tester, const Duration(minutes: 3));
        await _close(tester, container);
      },
    );
  }
}

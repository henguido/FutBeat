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
  bool standingsStale = false,
  String? standingsState,
}) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-09-01T21:00:00Z',
  'coverage': {
    'partial': false,
    'standings':
        standingsState ??
        (standings ? 'available' : (standingsPending ? 'pending' : 'missing')),
    'standingsPending': standingsPending,
    'standingsStale': standingsStale,
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
    '23. standings that arrive later appear in place; current tab kept',
    (tester) async {
      final server = _Server(
        detail: (_) => _detail(lineup: true, stats: true),
        context: (i) => i == 0
            ? _context(standingsPending: true)
            : _context(standings: true),
      );
      final container = await _open(tester, server);
      expect(find.text('Tabla'), findsOneWidget, reason: 'stable tab');
      await _tab(tester, 'Alineación');
      await _elapse(
        tester,
        standingsRetryDelays.first + const Duration(seconds: 2),
      );
      expect(_selectedTab(tester), 'Alineación');
      expect(
        server.contextReads,
        2,
        reason: 'stops once standings are available',
      );
      await _tab(tester, 'Tabla');
      expect(find.text('Clasificación'), findsOneWidget);
      await _elapse(tester, const Duration(minutes: 2));
      expect(server.contextReads, 2);
      await _close(tester, container);
    },
  );

  group('#98 Tabla is a stable state tab', () {
    testWidgets('1. AVAILABLE: Tabla tab with the exact rows', (tester) async {
      final server = _Server(
        detail: (_) => _detail(lineup: true, stats: true),
        context: (_) => _context(standings: true),
      );
      final container = await _open(tester, server);
      await _tab(tester, 'Tabla');
      expect(find.text('Clasificación'), findsOneWidget);
      expect(find.text('Local Sintético'), findsWidgets);
      expect(find.text('Visita Sintética'), findsWidgets);
      expect(find.text('Sin tabla disponible'), findsNothing);
      expect(server.contextReads, 1, reason: 'nothing pending: no refresh');
      await _close(tester, container);
    });

    testWidgets('2. PENDING without a table: tab visible + loading state', (
      tester,
    ) async {
      final server = _Server(
        detail: (_) => _detail(lineup: true, stats: true),
        context: (_) => _context(standingsPending: true),
      );
      final container = await _open(tester, server);
      await _tab(tester, 'Tabla');
      expect(find.text('Cargando tabla…'), findsOneWidget);
      expect(find.byKey(const ValueKey('match-refreshing')), findsOneWidget);
      await _elapse(tester, const Duration(minutes: 2));
      await _close(tester, container);
    });

    testWidgets('3. UNAVAILABLE: tab visible + "Sin tabla disponible"', (
      tester,
    ) async {
      final server = _Server(
        detail: (_) => _detail(lineup: true, stats: true),
        context: (_) => _context(standingsState: 'unavailable'),
      );
      final container = await _open(tester, server);
      await _tab(tester, 'Tabla');
      expect(find.text('Sin tabla disponible'), findsOneWidget);
      expect(find.text('Cargando tabla…'), findsNothing);
      await _elapse(tester, const Duration(minutes: 1));
      expect(server.contextReads, 1, reason: 'no refresh for NO_DATA');
      await _close(tester, container);
    });

    testWidgets('4. MISSING / not fetchable: stable empty state', (
      tester,
    ) async {
      final server = _Server(
        detail: (_) => _detail(lineup: true, stats: true),
        context: (_) => _context(),
      );
      final container = await _open(tester, server);
      await _tab(tester, 'Tabla');
      expect(find.text('Sin tabla disponible'), findsOneWidget);
      expect(find.byKey(const ValueKey('match-refreshing')), findsNothing);
      await _elapse(tester, const Duration(minutes: 1));
      expect(server.contextReads, 1);
      await _close(tester, container);
    });

    testWidgets(
      '5. stale + pending: the table stays visible while it refreshes',
      (tester) async {
        final server = _Server(
          detail: (_) => _detail(lineup: true, stats: true),
          context: (i) => i == 0
              ? _context(
                  standings: true,
                  standingsPending: true,
                  standingsStale: true,
                )
              : _context(standings: true),
        );
        final container = await _open(tester, server);
        await _tab(tester, 'Tabla');
        expect(find.text('Clasificación'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('standings-updating')),
          findsOneWidget,
        );
        for (var step = 0; step < 24; step++) {
          await tester.pump(const Duration(milliseconds: 500));
          expect(
            find.text('Clasificación'),
            findsOneWidget,
            reason: 'never hidden at step $step',
          );
        }
        expect(find.byKey(const ValueKey('standings-updating')), findsNothing);
        expect(server.contextReads, 2);
        expect(_selectedTab(tester), 'Tabla');
        await _close(tester, container);
      },
    );

    testWidgets(
      '6. pending then AVAILABLE on Tabla: rows appear without reopening',
      (tester) async {
        final server = _Server(
          detail: (_) => _detail(lineup: true, stats: true),
          context: (i) => i < 2
              ? _context(standingsPending: true)
              : _context(standings: true),
        );
        final container = await _open(tester, server);
        await _tab(tester, 'Tabla');
        expect(find.text('Cargando tabla…'), findsOneWidget);
        await _elapse(
          tester,
          standingsRetryDelays[0] +
              standingsRetryDelays[1] +
              const Duration(seconds: 2),
        );
        expect(find.text('Cargando tabla…'), findsNothing);
        expect(find.text('Clasificación'), findsOneWidget);
        expect(_selectedTab(tester), 'Tabla');
        expect(server.contextReads, 3);
        await _close(tester, container);
      },
    );

    testWidgets(
      '7. bounded retries: a table that never arrives settles (finite, no spinner)',
      (tester) async {
        final server = _Server(
          detail: (_) => _detail(lineup: true, stats: true),
          context: (_) => _context(standingsPending: true),
        );
        final container = await _open(tester, server);
        await _tab(tester, 'Tabla');
        await _elapse(tester, const Duration(minutes: 7));
        final total =
            1 + standingsRetryDelays.length + standingsSilentRetryDelays.length;
        expect(server.contextReads, total);
        expect(find.text('Cargando tabla…'), findsNothing);
        expect(find.text('Tabla aún no disponible'), findsOneWidget);
        expect(find.byKey(const ValueKey('match-refreshing')), findsNothing);
        await _elapse(tester, const Duration(minutes: 10));
        expect(server.contextReads, total, reason: 'no endless polling');
        await _close(tester, container);
      },
    );

    testWidgets(
      '9. pending past the visible retries: settled state + Reintentar',
      (tester) async {
        final server = _Server(
          detail: (_) => _detail(lineup: true, stats: true),
          context: (_) => _context(standingsPending: true),
        );
        final container = await _open(tester, server);
        await _tab(tester, 'Tabla');
        expect(find.text('Cargando tabla…'), findsOneWidget);
        await _elapse(
          tester,
          standingsRetryDelays.fold(Duration.zero, (a, b) => a + b) +
              const Duration(seconds: 2),
        );
        expect(server.contextReads, 1 + standingsRetryDelays.length);
        expect(find.text('Cargando tabla…'), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.text('Tabla aún no disponible'), findsOneWidget);
        expect(find.text('Reintentar'), findsOneWidget);
        await _close(tester, container);
      },
    );

    testWidgets(
      '10. Reintentar re-reads in place; an AVAILABLE answer shows the rows',
      (tester) async {
        var available = false;
        final server = _Server(
          detail: (_) => _detail(lineup: true, stats: true),
          context: (_) => available
              ? _context(standings: true)
              : _context(standingsPending: true),
        );
        final container = await _open(tester, server);
        await _tab(tester, 'Tabla');
        await _elapse(
          tester,
          standingsRetryDelays.fold(Duration.zero, (a, b) => a + b) +
              const Duration(seconds: 2),
        );
        final reads = server.contextReads;
        available = true;
        final retry = find.byKey(const ValueKey('standings-retry'));
        await tester.ensureVisible(retry);
        await tester.tap(retry);
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(server.contextReads, reads + 1, reason: 'one read per tap');
        expect(find.text('Clasificación'), findsOneWidget);
        expect(find.text('Reintentar'), findsNothing);
        expect(_selectedTab(tester), 'Tabla');
        await _elapse(tester, const Duration(minutes: 5));
        expect(
          server.contextReads,
          reads + 1,
          reason: 'available: nothing else',
        );
        await _close(tester, container);
      },
    );

    testWidgets(
      '11. a table answered during a silent revalidation appears by itself',
      (tester) async {
        // Pending through every visible refresh; available from the first
        // silent revalidation (read index 4, ~158 s after opening).
        final server = _Server(
          detail: (_) => _detail(lineup: true, stats: true),
          context: (i) => i < 1 + standingsRetryDelays.length
              ? _context(standingsPending: true)
              : _context(standings: true),
        );
        final container = await _open(tester, server);
        await _tab(tester, 'Tabla');
        final controller = tester
            .widget<TabBar>(find.byType(TabBar))
            .controller;
        await _elapse(
          tester,
          standingsRetryDelays.fold(Duration.zero, (a, b) => a + b) +
              const Duration(seconds: 2),
        );
        expect(find.text('Tabla aún no disponible'), findsOneWidget);
        await _elapse(
          tester,
          standingsSilentRetryDelays.first + const Duration(seconds: 2),
        );
        expect(find.text('Clasificación'), findsOneWidget);
        expect(find.text('Tabla aún no disponible'), findsNothing);
        final bar = tester.widget<TabBar>(find.byType(TabBar));
        expect(bar.controller, same(controller));
        expect(_selectedTab(tester), 'Tabla');
        expect(server.contextReads, 2 + standingsRetryDelays.length);
        await _elapse(tester, const Duration(minutes: 5));
        expect(server.contextReads, 2 + standingsRetryDelays.length);
        await _close(tester, container);
      },
    );

    testWidgets(
      '12. NO_DATA: no silent polling and no Reintentar over the negative cache',
      (tester) async {
        final server = _Server(
          detail: (_) => _detail(lineup: true, stats: true),
          context: (_) => _context(standingsState: 'unavailable'),
        );
        final container = await _open(tester, server);
        await _tab(tester, 'Tabla');
        expect(find.text('Sin tabla disponible'), findsOneWidget);
        expect(find.text('Reintentar'), findsNothing);
        await _elapse(tester, const Duration(minutes: 10));
        expect(server.contextReads, 1);
        expect(find.text('Reintentar'), findsNothing);
        await _close(tester, container);
      },
    );

    testWidgets(
      '8. state transitions keep the TabController and the selected tab',
      (tester) async {
        final states = [
          _context(standingsPending: true),
          _context(standings: true, standingsPending: true),
          _context(standingsState: 'unavailable'),
        ];
        final server = _Server(
          detail: (_) => _detail(lineup: true, stats: true),
          context: (i) => states[i.clamp(0, states.length - 1)],
        );
        final container = await _open(tester, server);
        await _tab(tester, 'Tabla');
        final controller = tester
            .widget<TabBar>(find.byType(TabBar))
            .controller;
        for (final wait in standingsRetryDelays.take(2)) {
          await _elapse(tester, wait + const Duration(seconds: 1));
          final bar = tester.widget<TabBar>(find.byType(TabBar));
          expect(bar.controller, same(controller));
          expect(bar.controller!.length, 4);
          expect(_selectedTab(tester), 'Tabla');
          expect(tester.takeException(), isNull);
        }
        expect(server.contextReads, 3);
        expect(find.text('Sin tabla disponible'), findsOneWidget);
        await _close(tester, container);
      },
    );
  });

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
      await _elapse(tester, const Duration(minutes: 7));
      final detailReads = server.detailReads;
      final contextReads = server.contextReads;
      expect(detailReads, lessThanOrEqualTo(6));
      expect(
        contextReads,
        1 + standingsRetryDelays.length + standingsSilentRetryDelays.length,
      );
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

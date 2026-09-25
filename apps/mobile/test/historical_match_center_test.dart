import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/match_screen.dart';

// Issue #101: historical Match Center is cache-first and partial-first.
// `available` means "displayable", not "complete": the server's
// `hydrationNeeded`/`pending` drive demand. One request-aware open, then fast
// read-only rechecks that always end. Everything synthetic.

const _match = 'fb_match_hist';

Map<String, dynamic> _context() => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-07-01T21:00:00Z',
  'coverage': {'standings': 'missing', 'standingsPending': false},
  'competitions': [
    {'id': 'fb_comp_hist', 'name': 'Liga Histórica'},
  ],
  'teams': [
    {'id': 'fb_team_hist_h', 'name': 'Local Histórico'},
    {'id': 'fb_team_hist_a', 'name': 'Visita Histórica'},
  ],
  'players': <dynamic>[],
  'standings': <dynamic>[],
  'matches': [
    {
      'id': _match,
      'competitionId': 'fb_comp_hist',
      'homeTeamId': 'fb_team_hist_h',
      'awayTeamId': 'fb_team_hist_a',
      'startTime': '2026-06-01T18:00:00Z',
      'status': 'FINISHED_PENDING_VERIFICATION',
      'season': '2026',
      'score': {'home': 2, 'away': 1},
      'events': [
        {
          'id': 'canon_goal_10',
          'type': 'GOAL',
          'minute': 10,
          'side': 'home',
          'label': 'Gol canónico',
        },
      ],
      'statistics': <dynamic>[],
    },
  ],
};

const _starter = {
  'id': 'p1',
  'canonicalId': 'fb_player_hist1',
  'name': 'Arquero Sintético',
  'number': '1',
};

Map<String, dynamic> _detail({
  bool available = true,
  String level = 'full',
  bool pending = false,
  bool hydrationNeeded = false,
  bool lineup = false,
  bool stats = false,
  String? stadium,
  List<Map<String, dynamic>> incidents = const [],
  String lineupState = 'missing',
  String statsState = 'missing',
}) => {
  'matchId': _match,
  'available': available,
  'pending': pending,
  'hydrationNeeded': hydrationNeeded,
  'detailLevel': level,
  'stadium': stadium,
  'coverage': {
    'detail': level == 'full' ? 'available' : (pending ? 'pending' : 'missing'),
    'lineup': lineup ? 'available' : lineupState,
    'statistics': stats ? 'available' : statsState,
    'stale': false,
    'hydrationNeeded': hydrationNeeded,
  },
  'home': lineup
      ? {
          'formation': '4-4-2',
          'starters': [_starter],
        }
      : <String, dynamic>{},
  'away': <String, dynamic>{},
  'statistics': stats
      ? [
          {'label': 'Shots on Goal', 'home': 5, 'away': 2},
        ]
      : <dynamic>[],
  'incidents': incidents,
  'videos': <dynamic>[],
};

const _partialGoal = {
  'type': 'GOAL',
  'minute': 10,
  'label': 'Gol',
  'detail': 'Anotador Parcial',
  'side': 'home',
};

Map<String, dynamic> _partial({bool pending = true}) => _detail(
  level: 'live',
  pending: pending,
  stadium: 'Estadio Parcial',
  incidents: [_partialGoal],
  lineupState: pending ? 'pending' : 'missing',
  statsState: pending ? 'pending' : 'missing',
);

Map<String, dynamic> _full() => _detail(
  lineup: true,
  stats: true,
  stadium: 'Estadio Parcial',
  incidents: [
    _partialGoal,
    {
      'type': 'YELLOW_CARD',
      'minute': 30,
      'label': 'Tarjeta amarilla',
      'side': 'away',
    },
  ],
);

class _Server {
  _Server(this.detail);

  /// (read index, request-aware?) -> detail JSON, or null for a failure.
  Map<String, dynamic>? Function(int read, bool request) detail;
  final List<bool> detailCalls = [];
  Completer<void>? gate;

  int get requestAware => detailCalls.where((request) => request).length;
  int get readOnly => detailCalls.where((request) => !request).length;

  Dio dio() => Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          if (options.path == '/v1/match-context') {
            handler.resolve(
              Response(requestOptions: options, data: _context()),
            );
            return;
          }
          final request = options.queryParameters['request'] != '0';
          final index = detailCalls.length;
          detailCalls.add(request);
          if (gate != null) await gate!.future;
          final data = detail(index, request);
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

Future<ProviderContainer> _open(WidgetTester tester, _Server server) async {
  tester.view.physicalSize = const Size(390, 820);
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
  await _mount(tester, container);
  return container;
}

Future<void> _mount(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: MatchScreen(id: _match)),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
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
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _elapse(WidgetTester tester, Duration total) async {
  for (
    var t = Duration.zero;
    t < total;
    t += const Duration(milliseconds: 250)
  ) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

final _scheduleLength = [
  const Duration(seconds: 2),
  const Duration(seconds: 4),
  const Duration(seconds: 8),
  const Duration(seconds: 15),
  const Duration(seconds: 30),
].length;

void main() {
  testWidgets('1. a partial historical detail paints immediately', (
    tester,
  ) async {
    final server = _Server((_, _) => _partial());
    final container = await _open(tester, server);
    expect(find.text('Estadio Parcial'), findsWidgets);
    expect(find.text('Anotador Parcial'), findsWidgets);
    await _tab(tester, 'Alineación');
    expect(find.text('Cargando alineaciones…'), findsOneWidget);
    await _elapse(tester, const Duration(minutes: 2));
    await _close(tester, container);
  });

  test('2. partial available=true still requests hydration when the server says so', () async {
    final server = _Server((read, request) {
      if (request) return _partial();
      // Read-only re-entry: the 1st says hydration would help again (e.g.
      // the earlier demand expired), later ones do not.
      return _partial(pending: false)..['hydrationNeeded'] = read == 1;
    });
    final repo = ApiRepository(server.dio());
    final first = await repo.loadMatchDetail(_match);
    expect(first.available, true);
    expect(server.detailCalls, [true], reason: 'one request-aware open');
    // Re-entry: read-only, and the server says demand would help again.
    await repo.loadMatchDetail(_match);
    expect(server.detailCalls, [true, false, true]);
    // Re-entry: read-only; nothing needed -> no request.
    await repo.loadMatchDetail(_match);
    expect(server.detailCalls, [true, false, true, false]);
  });

  testWidgets('3. full cached detail: one call, no redundant request', (
    tester,
  ) async {
    final server = _Server((_, _) => _full());
    final container = await _open(tester, server);
    await _elapse(tester, const Duration(minutes: 1));
    expect(server.detailCalls, [true]);
    await _tab(tester, 'Alineación');
    expect(find.text('AS'), findsWidgets);
    await _close(tester, container);
  });

  testWidgets('4/5. cold open: ONE request-aware call; the first fast read '
      'shows the finished detail', (tester) async {
    final server = _Server(
      (read, _) => read == 0
          ? _detail(
              available: false,
              level: 'none',
              pending: true,
              lineupState: 'pending',
              statsState: 'pending',
            )
          : _full(),
    );
    final container = await _open(tester, server);
    expect(server.detailCalls, [true], reason: 'no read-then-request');
    await _tab(tester, 'Alineación');
    expect(find.text('Cargando alineaciones…'), findsOneWidget);
    await _elapse(tester, const Duration(milliseconds: 2500));
    expect(server.detailCalls, [true, false]);
    expect(find.text('AS'), findsWidgets);
    expect(find.byKey(const ValueKey('match-refreshing')), findsNothing);
    await _elapse(tester, const Duration(minutes: 1));
    expect(server.detailCalls, [
      true,
      false,
    ], reason: 'complete: rechecks stop');
    await _close(tester, container);
  });

  testWidgets('6. read-only rechecks are bounded and end in a stable state', (
    tester,
  ) async {
    final server = _Server(
      (_, _) => _detail(
        available: false,
        level: 'none',
        pending: true,
        lineupState: 'pending',
        statsState: 'pending',
      ),
    );
    final container = await _open(tester, server);
    await _elapse(tester, const Duration(minutes: 2));
    expect(server.requestAware, 1);
    expect(server.readOnly, _scheduleLength);
    await _tab(tester, 'Alineación');
    expect(find.text('Sin alineaciones'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await _elapse(tester, const Duration(minutes: 3));
    expect(server.detailCalls.length, 1 + _scheduleLength);
    await _close(tester, container);
  });

  testWidgets('7. failed rechecks keep the partial data on screen', (
    tester,
  ) async {
    final server = _Server((read, _) => read == 0 ? _partial() : null);
    final container = await _open(tester, server);
    for (var step = 0; step < 240; step++) {
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Estadio Parcial'), findsWidgets, reason: 'step $step');
      expect(find.text('Anotador Parcial'), findsWidgets);
    }
    expect(server.requestAware, 1);
    await _close(tester, container);
  });

  testWidgets('8. a missing lineup never hides events or statistics', (
    tester,
  ) async {
    final server = _Server(
      (_, _) => _detail(
        stats: true,
        incidents: [_partialGoal],
        lineupState: 'unavailable',
      ),
    );
    final container = await _open(tester, server);
    expect(find.text('Anotador Parcial'), findsWidgets);
    await _tab(tester, 'Estadísticas');
    expect(find.text('Tiros a puerta'), findsWidgets);
    await _tab(tester, 'Alineación');
    expect(find.text('Sin alineaciones'), findsOneWidget);
    await _close(tester, container);
  });

  testWidgets('9. missing player photos never hide the lineup', (tester) async {
    final server = _Server(
      (_, _) => _full()
        ..['coverage'] = {
          ..._full()['coverage'] as Map<String, dynamic>,
          'lineupEnrichmentPending': true,
        },
    );
    final container = await _open(tester, server);
    await _tab(tester, 'Alineación');
    expect(find.text('AS'), findsWidgets, reason: 'initials without a photo');
    expect(find.text('Cargando alineaciones…'), findsNothing);
    await _elapse(tester, const Duration(minutes: 1));
    await _close(tester, container);
  });

  testWidgets('10. reopening the same match paints from memory at once', (
    tester,
  ) async {
    final server = _Server((_, _) => _full());
    final container = await _open(tester, server);
    await _tab(tester, 'Alineación');
    expect(find.text('AS'), findsWidgets);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump(matchCacheRetention + const Duration(seconds: 1));
    // The server is slow now: the remembered detail is shown meanwhile.
    server.gate = Completer<void>();
    await _mount(tester, container);
    await _tab(tester, 'Alineación');
    expect(find.text('AS'), findsWidgets);
    server.gate!.complete();
    await _elapse(tester, const Duration(seconds: 1));
    expect(find.text('AS'), findsWidgets);
    await _close(tester, container);
  });

  testWidgets(
    '11. >90 days: persisted data, stable empty sections, no spinner',
    (tester) async {
      final server = _Server(
        (_, _) => _detail(level: 'live', incidents: [_partialGoal]),
      );
      final container = await _open(tester, server);
      expect(find.text('Anotador Parcial'), findsWidgets);
      await _tab(tester, 'Alineación');
      expect(find.text('Sin alineaciones'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await _elapse(tester, const Duration(minutes: 2));
      expect(server.detailCalls, [
        true,
      ], reason: 'nothing pending: no rechecks');
      await _close(tester, container);
    },
  );

  test('12. timeline merges canonical events and rich incidents without duplicates', () {
    final data = Snapshot(_context());
    final match = data.matches.single;
    final timeline = mergedMatchTimeline(match, MatchDetail(_full()));
    final goals = timeline.where((e) => e['type'] == 'GOAL').toList();
    expect(goals, hasLength(1), reason: 'same goal from both sources');
    expect(goals.single['detailSource'], true, reason: 'rich one kept');
    expect(timeline.where((e) => e['type'] == 'YELLOW_CARD'), hasLength(1));
    // Canonical-only (no detail yet): the timeline is still there.
    final partial = mergedMatchTimeline(match, MatchDetail.empty(_match));
    expect(partial.where((e) => e['type'] == 'GOAL'), hasLength(1));
  });
}

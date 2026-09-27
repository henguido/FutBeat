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
  int previewReads = 0;
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
          if (options.path == '/v1/match-preview') {
            // #99 phase 2: separate DB-only read (not a detail read).
            previewReads++;
            handler.resolve(
              Response(
                requestOptions: options,
                data: {
                  'schemaVersion': 1,
                  'matchId': options.queryParameters['id'],
                },
              ),
            );
            return;
          }
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

/// Default read-only recheck schedule (detailPollScheduleProvider).
const _schedule = [
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 15),
  Duration(seconds: 40),
];
final _scheduleLength = _schedule.length;

Map<String, dynamic> _waiting() => _detail(
  available: false,
  level: 'none',
  pending: true,
  lineupState: 'pending',
  statsState: 'pending',
);

void main() {
  testWidgets('1. a partial historical detail paints immediately', (
    tester,
  ) async {
    final server = _Server((_, _) => _partial());
    final container = await _open(tester, server);
    // Hechos: general info at once; the chronology lives only in En vivo.
    expect(find.text('Estadio Parcial'), findsWidgets);
    expect(find.text('Anotador Parcial'), findsNothing);
    await _tab(tester, 'En vivo');
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

  test('the default schedule really covers the 1-minute cron fallback', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final schedule = container.read(detailPollScheduleProvider);
    expect(schedule, _schedule);
    final total = schedule.fold(Duration.zero, (a, b) => a + b);
    expect(total, greaterThan(const Duration(seconds: 65)));
    expect(schedule.length, 5);
  });

  testWidgets(
    'cron fallback: detail finished after ~60 s is found by the last read, '
    'in place, then nothing more',
    (tester) async {
      // Reads 1-4 (2, 6, 14, 29 s) still pending; the provider completes at
      // ~61 s (next cron + GOAL); read 5 (69 s) finds it.
      final server = _Server((read, _) => read < 5 ? _waiting() : _full());
      final container = await _open(tester, server);
      await _tab(tester, 'Alineación');
      expect(
        find.byKey(const ValueKey('match-refreshing')),
        findsOneWidget,
        reason: 'a fresh open may show a discreet hydration signal',
      );
      await _elapse(
        tester,
        matchDetailRefreshIndicatorDuration + const Duration(seconds: 1),
      );
      expect(
        find.byKey(const ValueKey('match-refreshing')),
        findsNothing,
        reason: 'long cron-fallback rechecks continue silently',
      );
      expect(
        find.text('Cargando alineaciones…'),
        findsOneWidget,
        reason:
            'the section may still wait while the global busy signal is gone',
      );
      await _elapse(tester, const Duration(seconds: 51));
      expect(server.detailCalls, [true, false, false, false, false]);
      expect(find.text('Cargando alineaciones…'), findsOneWidget);
      await _elapse(tester, const Duration(seconds: 10));
      expect(server.detailCalls.length, 6);
      expect(find.text('AS'), findsWidgets, reason: 'appears without reopen');
      expect(find.byKey(const ValueKey('match-refreshing')), findsNothing);
      await _elapse(tester, const Duration(minutes: 3));
      expect(server.detailCalls.length, 6, reason: 'no reads after complete');
      expect(server.requestAware, 1);
      await _close(tester, container);
    },
  );

  testWidgets(
    'pending keeps rechecking even when hydrationNeeded=false (demand queued)',
    (tester) async {
      // Request-aware open of a partial: the demand now exists, so
      // hydrationNeeded=false, but pending=true until the detail lands.
      final server = _Server(
        (read, _) =>
            read < 2 ? (_partial()..['hydrationNeeded'] = false) : _full(),
      );
      final container = await _open(tester, server);
      expect(find.text('Estadio Parcial'), findsWidgets);
      await _elapse(tester, const Duration(seconds: 7));
      expect(server.detailCalls, [true, false, false]);
      await _tab(tester, 'Alineación');
      expect(find.text('AS'), findsWidgets);
      await _elapse(tester, const Duration(minutes: 2));
      expect(server.detailCalls.length, 3);
      await _close(tester, container);
    },
  );

  test(
    'an expired demand is requested again from the same repository (once)',
    () async {
      // 0: request-aware open -> demand queued (pending, not needed).
      // 1-5: bounded read-only rechecks, still pending (quota/backoff).
      // Later re-entry: the demand expired -> read says hydrationNeeded.
      var expired = false;
      final server = _Server((read, request) {
        if (request) return _partial()..['hydrationNeeded'] = false;
        return expired
            ? (_partial(pending: false)..['hydrationNeeded'] = true)
            : (_partial()..['hydrationNeeded'] = false);
      });
      final repo = ApiRepository(server.dio());
      await repo.loadMatchDetail(_match);
      for (var i = 0; i < _scheduleLength; i++) {
        expect((await repo.readMatchDetail(_match)).pending, true);
      }
      expect(server.requestAware, 1);
      // Re-entry while the demand is still queued: read-only only.
      await repo.loadMatchDetail(_match);
      expect(server.requestAware, 1);
      expired = true;
      // Re-entry after expiry/backoff: exactly one new request-aware call,
      // even with two concurrent opens (in-flight dedupe kept).
      await Future.wait([
        repo.loadMatchDetail(_match),
        repo.loadMatchDetail(_match),
      ]);
      expect(server.requestAware, 2);
    },
  );

  testWidgets('6. read-only rechecks are bounded and end in a stable state', (
    tester,
  ) async {
    final server = _Server((_, _) => _waiting());
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
    expect(find.text('Estadio Parcial'), findsWidgets);
    await _tab(tester, 'En vivo');
    for (var step = 0; step < 240; step++) {
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Anotador Parcial'), findsWidgets, reason: 'step $step');
    }
    await _tab(tester, 'Hechos');
    expect(find.text('Estadio Parcial'), findsWidgets);
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
    await _tab(tester, 'En vivo');
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

  testWidgets(
    '10. a shorter non-empty correction replaces remembered lineup and stats',
    (tester) async {
      Map<String, dynamic> player(int index, String suffix) => {
        'id': 'p$index',
        'canonicalId': 'fb_player_hist$index',
        'name': 'Jugador $index $suffix',
        'number': '$index',
      };
      Map<String, dynamic> statistic(String label, int value) => {
        'label': label,
        'home': value,
        'away': value - 1,
      };
      final remembered = _full();
      (remembered['home'] as Map<String, dynamic>)['starters'] = [
        for (var index = 1; index <= 10; index++) player(index, 'anterior'),
        player(11, 'obsoleto'),
      ];
      (remembered['home'] as Map<String, dynamic>)['coach'] = {
        'name': 'Entrenador Viejo',
      };
      (remembered['home'] as Map<String, dynamic>)['substitutes'] = [
        for (var index = 12; index <= 18; index++) player(index, 'banca vieja'),
      ];
      remembered['statistics'] = [
        statistic('Possession', 55),
        statistic('Total Shots', 12),
        statistic('Shots on Goal', 6),
        statistic('Corner Kicks', 5),
        statistic('Fouls', 9),
      ];
      final corrected = _full();
      (corrected['home'] as Map<String, dynamic>)['starters'] = [
        for (var index = 1; index <= 10; index++) player(index, 'corregido'),
      ];
      corrected['home'] = <String, dynamic>{
        ...corrected['home'] as Map<String, dynamic>,
        'substitutes': [
          for (var index = 12; index <= 14; index++)
            player(index, 'banca corregida'),
        ],
        'coach': null,
      };
      corrected['statistics'] = [
        statistic('Possession', 51),
        statistic('Total Shots', 10),
        statistic('Shots on Goal', 4),
        statistic('Corner Kicks', 3),
      ];
      final server = _Server((read, _) => read == 0 ? remembered : corrected);
      final container = await _open(tester, server);
      await _tab(tester, 'Alineación');
      expect(find.textContaining('obsoleto'), findsWidgets);
      expect(find.text('Entrenador Viejo'), findsOneWidget);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const SizedBox(),
        ),
      );
      await tester.pump(matchCacheRetention + const Duration(seconds: 1));
      final memory = container.read(matchDetailMemoryProvider);
      memory[_match] = MatchDetail({
        ...memory[_match]!.json,
        'coverage': {
          ...memory[_match]!.coverage!,
          'lineupEnrichmentPending': true,
        },
      });
      // The server is slow now: the remembered detail is shown meanwhile.
      server.gate = Completer<void>();
      await _mount(tester, container);
      await _tab(tester, 'Alineación');
      expect(find.textContaining('obsoleto'), findsWidgets);
      server.gate!.complete();
      await _elapse(tester, const Duration(seconds: 1));
      expect(find.textContaining('corregido'), findsWidgets);
      expect(find.textContaining('obsoleto'), findsNothing);
      expect(find.textContaining('banca corregida'), findsWidgets);
      expect(find.textContaining('banca vieja'), findsNothing);
      expect(find.text('Entrenador Viejo'), findsNothing);
      expect(memory[_match]!.homeCoach, isNull);
      expect(memory[_match]!.homeStarters, hasLength(10));
      expect(memory[_match]!.homeSubstitutes, hasLength(3));
      expect(memory[_match]!.lineupEnrichmentPending, isFalse);
      await _tab(tester, 'Estadísticas');
      expect(find.text('Tiros a puerta'), findsWidgets);
      expect(find.text('Córners'), findsWidgets);
      expect(find.text('Faltas'), findsNothing);
      await _close(tester, container);
    },
  );

  testWidgets('an authoritative side can clear its obsolete bench', (
    tester,
  ) async {
    final remembered = _full();
    (remembered['home'] as Map<String, dynamic>)['substitutes'] = [
      for (var index = 1; index <= 5; index++)
        {'name': 'Suplente obsoleto $index'},
    ];
    final corrected = _full();
    (corrected['home'] as Map<String, dynamic>)['substitutes'] = <dynamic>[];
    final server = _Server((read, _) => read == 0 ? remembered : corrected);
    final container = await _open(tester, server);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump(matchCacheRetention + const Duration(seconds: 1));
    await _mount(tester, container);
    await _elapse(tester, const Duration(seconds: 1));
    await _tab(tester, 'Alineación');
    expect(find.textContaining('Suplente obsoleto'), findsNothing);
    expect(
      container.read(matchDetailMemoryProvider)[_match]!.homeSubstitutes,
      isEmpty,
    );
    await _close(tester, container);
  });

  testWidgets('authoritative membership retains missing player enrichment', (
    tester,
  ) async {
    final remembered = _full();
    (remembered['home'] as Map<String, dynamic>)['starters'] = [
      {
        ..._starter,
        'image': 'https://img.example/player.png',
        'media': {
          'url': 'https://img.example/canonical.png',
          'verificationStatus': 'VERIFIED',
        },
      },
      {'id': 'removed', 'name': 'Jugador Eliminado'},
    ];
    final corrected = _full();
    (corrected['home'] as Map<String, dynamic>)['starters'] = [
      {..._starter, 'canonicalId': null, 'image': null, 'media': null},
    ];
    final server = _Server((read, _) => read == 0 ? remembered : corrected);
    final container = await _open(tester, server);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump(matchCacheRetention + const Duration(seconds: 1));
    await _mount(tester, container);
    await _elapse(tester, const Duration(seconds: 1));
    final starters = container
        .read(matchDetailMemoryProvider)[_match]!
        .homeStarters;
    expect(starters, hasLength(1), reason: 'removed membership stays removed');
    expect(starters.single['canonicalId'], 'fb_player_hist1');
    expect(starters.single['image'], 'https://img.example/player.png');
    expect((starters.single['media'] as Map)['verificationStatus'], 'VERIFIED');
    await _close(tester, container);
  });

  testWidgets('a player moved to the bench retains missing enrichment', (
    tester,
  ) async {
    final remembered = _full();
    (remembered['home'] as Map<String, dynamic>)['starters'] = [
      {..._starter, 'image': 'https://img.example/player.png'},
    ];
    final corrected = _full();
    corrected['home'] = <String, dynamic>{
      ...corrected['home'] as Map<String, dynamic>,
      'starters': <dynamic>[],
      'substitutes': [
        {..._starter, 'canonicalId': null, 'image': null},
      ],
    };
    final server = _Server((read, _) => read == 0 ? remembered : corrected);
    final container = await _open(tester, server);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump(matchCacheRetention + const Duration(seconds: 1));
    await _mount(tester, container);
    await _elapse(tester, const Duration(seconds: 1));
    final detail = container.read(matchDetailMemoryProvider)[_match]!;
    expect(detail.homeStarters, isEmpty);
    expect(detail.homeSubstitutes, hasLength(1));
    expect(detail.homeSubstitutes.single['canonicalId'], 'fb_player_hist1');
    expect(
      detail.homeSubstitutes.single['image'],
      'https://img.example/player.png',
    );
    await _close(tester, container);
  });

  testWidgets('a player moved across sides retains missing enrichment', (
    tester,
  ) async {
    final remembered = _full();
    (remembered['home'] as Map<String, dynamic>)['starters'] = [
      {..._starter, 'image': 'https://img.example/player.png'},
    ];
    final corrected = _full();
    corrected['home'] = {
      ...corrected['home'] as Map<String, dynamic>,
      'starters': <dynamic>[],
      'substitutes': [
        {'name': 'Reserva local autoritativa'},
      ],
    };
    corrected['away'] = {
      ...corrected['away'] as Map<String, dynamic>,
      'starters': [
        {..._starter, 'canonicalId': null, 'image': null},
      ],
    };
    final server = _Server((read, _) => read == 0 ? remembered : corrected);
    final container = await _open(tester, server);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump(matchCacheRetention + const Duration(seconds: 1));
    await _mount(tester, container);
    await _elapse(tester, const Duration(seconds: 1));
    final detail = container.read(matchDetailMemoryProvider)[_match]!;
    expect(detail.awayStarters, hasLength(1));
    expect(detail.awayStarters.single['canonicalId'], 'fb_player_hist1');
    expect(
      detail.awayStarters.single['image'],
      'https://img.example/player.png',
    );
    await _close(tester, container);
  });

  testWidgets('a lower-ranked refresh preserves full lineup and statistics', (
    tester,
  ) async {
    final remembered = _full();
    (remembered['home'] as Map<String, dynamic>)['starters'] = [
      for (var index = 1; index <= 11; index++)
        {'id': 'full-$index', 'name': 'Titular completo $index'},
    ];
    (remembered['home'] as Map<String, dynamic>)['formation'] = '4-3-3';
    remembered['statistics'] = [
      for (var index = 1; index <= 5; index++)
        {'label': 'Estadística completa $index', 'home': index, 'away': 0},
    ];
    final live = _detail(level: 'live', lineup: true, stats: true);
    live['home'] = {
      'formation': '3-5-2',
      'starters': [
        {'id': 'live-only', 'name': 'Fila parcial en vivo'},
      ],
      'substitutes': <dynamic>[],
      'coach': null,
    };
    live['statistics'] = [
      {'label': 'Fila estadística parcial', 'home': 1, 'away': 0},
    ];
    final server = _Server((read, _) => read == 0 ? remembered : live);
    final container = await _open(tester, server);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump(matchCacheRetention + const Duration(seconds: 1));
    await _mount(tester, container);
    await _elapse(tester, const Duration(seconds: 1));
    final detail = container.read(matchDetailMemoryProvider)[_match]!;
    expect(detail.detailLevel, 'full');
    expect(detail.homeStarters, hasLength(11));
    expect(detail.homeStarters.first['name'], 'Titular completo 1');
    expect(detail.homeFormation, '4-3-3');
    expect(detail.statistics, hasLength(5));
    expect(detail.statistics.first['label'], 'Estadística completa 1');
    await _close(tester, container);
  });

  testWidgets('a successful empty video read removes a withdrawn video', (
    tester,
  ) async {
    final remembered = _full()
      ..['videos'] = [
        {
          'videoId': 'abcDEF12345',
          'url': 'https://www.youtube.com/watch?v=abcDEF12345',
        },
      ];
    final corrected = _full()
      ..['videos'] = <dynamic>[]
      ..['coverage'] = {
        ..._full()['coverage'] as Map<String, dynamic>,
        'videos': 'available',
      };
    final server = _Server((read, _) => read == 0 ? remembered : corrected);
    final container = await _open(tester, server);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump(matchCacheRetention + const Duration(seconds: 1));
    await _mount(tester, container);
    await _elapse(tester, const Duration(seconds: 1));
    expect(container.read(matchDetailMemoryProvider)[_match]!.videos, isEmpty);
    await _close(tester, container);
  });

  testWidgets('a failed video read preserves the remembered video', (
    tester,
  ) async {
    final remembered = _full()
      ..['videos'] = [
        {
          'videoId': 'abcDEF12345',
          'url': 'https://www.youtube.com/watch?v=abcDEF12345',
        },
      ];
    final failed = _full()
      ..['videos'] = <dynamic>[]
      ..['coverage'] = {
        ..._full()['coverage'] as Map<String, dynamic>,
        'videos': 'unavailable',
      };
    final server = _Server((read, _) => read == 0 ? remembered : failed);
    final container = await _open(tester, server);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump(matchCacheRetention + const Duration(seconds: 1));
    await _mount(tester, container);
    await _elapse(tester, const Duration(seconds: 1));
    expect(
      container.read(matchDetailMemoryProvider)[_match]!.videos,
      hasLength(1),
    );
    await _close(tester, container);
  });

  testWidgets('an authoritative bench can clear obsolete starters', (
    tester,
  ) async {
    final remembered = _full();
    final corrected = _full();
    corrected['home'] = <String, dynamic>{
      ...corrected['home'] as Map<String, dynamic>,
      'starters': <dynamic>[],
      'substitutes': [
        {'name': 'Único suplente nuevo'},
      ],
    };
    final server = _Server((read, _) => read == 0 ? remembered : corrected);
    final container = await _open(tester, server);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump(matchCacheRetention + const Duration(seconds: 1));
    await _mount(tester, container);
    await _elapse(tester, const Duration(seconds: 1));
    final detail = container.read(matchDetailMemoryProvider)[_match]!;
    expect(detail.homeStarters, isEmpty);
    expect(detail.homeSubstitutes, hasLength(1));
    expect(detail.homeSubstitutes.single['name'], 'Único suplente nuevo');
    await _close(tester, container);
  });

  testWidgets('authoritative home does not clear a transient empty away side', (
    tester,
  ) async {
    final remembered = _full();
    remembered['away'] = {
      'starters': [
        {'name': 'Visitante conservado'},
      ],
      'substitutes': [
        {'name': 'Banca visitante conservada'},
      ],
    };
    final corrected = _full();
    corrected['away'] = {
      'starters': <dynamic>[],
      'substitutes': <dynamic>[],
      'coach': null,
    };
    final server = _Server((read, _) => read == 0 ? remembered : corrected);
    final container = await _open(tester, server);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump(matchCacheRetention + const Duration(seconds: 1));
    await _mount(tester, container);
    await _elapse(tester, const Duration(seconds: 1));
    final detail = container.read(matchDetailMemoryProvider)[_match]!;
    expect(detail.awayStarters.single['name'], 'Visitante conservado');
    expect(detail.awaySubstitutes.single['name'], 'Banca visitante conservada');
    await _close(tester, container);
  });

  testWidgets('a corrected lineup replaces its remembered coach', (
    tester,
  ) async {
    final remembered = _full();
    (remembered['home'] as Map<String, dynamic>)['coach'] = {
      'name': 'Entrenador Viejo',
    };
    final corrected = _full();
    (corrected['home'] as Map<String, dynamic>)['coach'] = {
      'name': 'Entrenador Nuevo',
    };
    final server = _Server((read, _) => read == 0 ? remembered : corrected);
    final container = await _open(tester, server);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump(matchCacheRetention + const Duration(seconds: 1));
    await _mount(tester, container);
    await _elapse(tester, const Duration(seconds: 1));
    await _tab(tester, 'Alineación');
    expect(find.text('Entrenador Nuevo'), findsOneWidget);
    expect(find.text('Entrenador Viejo'), findsNothing);
    expect(
      container.read(matchDetailMemoryProvider)[_match]!.homeCoach?['name'],
      'Entrenador Nuevo',
    );
    await _close(tester, container);
  });

  testWidgets('an empty refresh retains a remembered coach', (tester) async {
    final remembered = _full();
    (remembered['home'] as Map<String, dynamic>)['coach'] = {
      'name': 'Entrenador Conservado',
    };
    final server = _Server((read, _) => read == 0 ? remembered : _partial());
    final container = await _open(tester, server);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump(matchCacheRetention + const Duration(seconds: 1));
    await _mount(tester, container);
    await _elapse(tester, const Duration(seconds: 1));
    await _tab(tester, 'Alineación');
    expect(find.text('Entrenador Conservado'), findsOneWidget);
    expect(
      container.read(matchDetailMemoryProvider)[_match]!.homeCoach?['name'],
      'Entrenador Conservado',
    );
    await _close(tester, container);
  });

  testWidgets('a new coach-only observation replaces the remembered coach', (
    tester,
  ) async {
    final remembered = _full();
    (remembered['home'] as Map<String, dynamic>)['coach'] = {
      'name': 'Entrenador Viejo',
    };
    final coachOnly = _partial();
    coachOnly['home'] = {
      'starters': <dynamic>[],
      'substitutes': <dynamic>[],
      'coach': {'name': 'Entrenador Nuevo'},
    };
    final server = _Server((read, _) => read == 0 ? remembered : coachOnly);
    final container = await _open(tester, server);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump(matchCacheRetention + const Duration(seconds: 1));
    await _mount(tester, container);
    await _elapse(tester, const Duration(seconds: 1));
    await _tab(tester, 'Alineación');
    expect(find.text('Entrenador Nuevo'), findsOneWidget);
    expect(find.text('Entrenador Viejo'), findsNothing);
    expect(
      container.read(matchDetailMemoryProvider)[_match]!.homeCoach?['name'],
      'Entrenador Nuevo',
    );
    await _close(tester, container);
  });

  testWidgets('an empty refresh retains remembered lineup and statistics', (
    tester,
  ) async {
    final server = _Server((read, _) => read == 0 ? _full() : _partial());
    final container = await _open(tester, server);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump(matchCacheRetention + const Duration(seconds: 1));
    await _mount(tester, container);
    await _elapse(tester, const Duration(seconds: 1));
    await _tab(tester, 'Alineación');
    expect(find.text('AS'), findsWidgets);
    await _tab(tester, 'Estadísticas');
    expect(find.text('Tiros a puerta'), findsWidgets);
    await _close(tester, container);
  });

  testWidgets('formation alone keeps a pending lineup in its loading state', (
    tester,
  ) async {
    Map<String, dynamic> formationOnly({required bool pending}) {
      final detail = _detail(
        level: 'partial',
        pending: pending,
        lineupState: pending ? 'pending' : 'missing',
      );
      detail['home'] = {
        'formation': '4-3-3',
        'starters': <dynamic>[],
        'substitutes': <dynamic>[],
        'coach': null,
      };
      return detail;
    }

    final server = _Server((read, _) => formationOnly(pending: read > 0));
    final container = await _open(tester, server);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump(matchCacheRetention + const Duration(seconds: 1));
    await _mount(tester, container);
    await _elapse(tester, const Duration(seconds: 1));
    await _tab(tester, 'Alineación');
    expect(find.text('Cargando alineaciones…'), findsOneWidget);
    expect(find.text('Sin alineaciones'), findsNothing);
    await _close(tester, container);
  });

  testWidgets('a missing remembered section adopts the latest pending state', (
    tester,
  ) async {
    final server = _Server(
      (read, _) =>
          read == 0 ? _detail(level: 'full', lineup: true) : _partial(),
    );
    final container = await _open(tester, server);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump(matchCacheRetention + const Duration(seconds: 1));
    await _mount(tester, container);
    await _elapse(tester, const Duration(seconds: 1));
    await _tab(tester, 'Estadísticas');
    expect(find.text('Cargando estadísticas…'), findsOneWidget);
    expect(find.text('Sin estadísticas'), findsNothing);
    await _close(tester, container);
  });

  testWidgets(
    '11. >90 days: persisted data, stable empty sections, no spinner',
    (tester) async {
      final server = _Server(
        (_, _) => _detail(level: 'live', incidents: [_partialGoal]),
      );
      final container = await _open(tester, server);
      await _tab(tester, 'En vivo');
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

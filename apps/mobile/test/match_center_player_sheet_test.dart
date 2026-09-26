import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/match_screen.dart';
import 'package:go_router/go_router.dart';

// #99 player sheet: tapping a player in Alineación, Top Rated or the per-team
// block opens a local panel (no request); "Ver perfil" only for canonical
// players. Only fields the lineup payload really carries are shown.

const _match = 'fb_match_ps';
const _home = 'fb_team_ps_home';
const _away = 'fb_team_ps_away';

Map<String, dynamic> _context() {
  final now = DateTime.now().toUtc();
  return {
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': now.toIso8601String(),
    'coverage': {'standings': 'missing', 'standingsPending': false},
    'competitions': [
      {'id': 'fb_comp_ps', 'name': 'Liga Panel'},
    ],
    'teams': [
      {'id': _home, 'name': 'Local Panel'},
      {'id': _away, 'name': 'Visita Panel'},
    ],
    'players': <dynamic>[],
    'standings': <dynamic>[],
    'matches': [
      {
        'id': _match,
        'competitionId': 'fb_comp_ps',
        'homeTeamId': _home,
        'awayTeamId': _away,
        'startTime': now.subtract(const Duration(hours: 3)).toIso8601String(),
        'status': 'VERIFIED',
        'season': '2026',
        'score': {'home': 1, 'away': 0},
        'events': const <dynamic>[],
        'statistics': const <dynamic>[],
      },
    ],
  };
}

Map<String, dynamic> _player(
  String id,
  String name, {
  String? canonicalId,
  String? number,
  String? position,
  num? rating,
  int? age,
  bool captain = false,
  int lineupPosition = 1,
}) => {
  'id': id,
  'canonicalId': canonicalId,
  'name': name,
  'number': number,
  'position': position,
  'lineupPosition': lineupPosition,
  'age': age,
  'image': null,
  'rating': rating,
  'captain': captain,
};

// A goal (p9, assisted by p10), a yellow for p9, then p9 -> p12.
final _incidents = [
  {
    'type': 'GOAL',
    'minute': 23,
    'side': 'home',
    'playerId': 'p9',
    'assistPlayerId': 'p10',
  },
  {'type': 'YELLOW_CARD', 'minute': 40, 'side': 'home', 'playerId': 'p9'},
  {
    'type': 'SUBSTITUTION',
    'minute': 70,
    'side': 'home',
    'outPlayerId': 'p9',
    'inPlayerId': 'p12',
  },
];

Map<String, dynamic> _detail({
  List<Map<String, dynamic>>? starters,
  List<Map<String, dynamic>>? substitutes,
  List<Map<String, dynamic>> away = const [],
}) => {
  'matchId': _match,
  'available': true,
  'pending': false,
  'hydrationNeeded': false,
  'detailLevel': 'full',
  'home': {
    'formation': '4-3-3',
    'starters':
        starters ??
        [
          _player(
            'p9',
            'Nasibov',
            canonicalId: 'fb_player_9',
            number: '9',
            position: 'Forward',
            rating: 8.4,
            age: 27,
            captain: true,
          ),
          _player(
            'p10',
            'Vagabov',
            number: '10',
            position: 'Midfielder',
            rating: 7.1,
            lineupPosition: 2,
          ),
        ],
    'substitutes':
        substitutes ??
        [
          _player(
            'p12',
            'Suplente Panel',
            canonicalId: 'fb_player_12',
            number: '12',
            rating: 6.6,
            lineupPosition: 12,
          ),
        ],
  },
  'away': {'formation': '4-3-3', 'starters': away, 'substitutes': const []},
  'statistics': const <dynamic>[],
  'incidents': _incidents,
  'videos': const <dynamic>[],
};

ProviderContainer? _container;

/// Unmount inside the test body (the real detail provider owns timers).
Future<void> _close(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 10));
  await tester.pumpWidget(const SizedBox());
  _container?.dispose();
  _container = null;
}

class _Server {
  _Server(this.detail);
  final Map<String, dynamic> detail;
  int detailReads = 0;

  Dio dio() => Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/v1/match-context') {
            handler.resolve(
              Response(requestOptions: options, data: _context()),
            );
            return;
          }
          if (options.path == '/v1/match-preview') {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response(requestOptions: options, statusCode: 503),
                type: DioExceptionType.badResponse,
              ),
            );
            return;
          }
          if (options.path == '/v1/match-detail') detailReads++;
          handler.resolve(Response(requestOptions: options, data: detail));
        },
      ),
    );
}

Future<_Server> _open(
  WidgetTester tester, {
  Map<String, dynamic>? detail,
  double width = 390,
}) async {
  final server = _Server(detail ?? _detail());
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final db = AppDatabase(NativeDatabase.memory());
  await tester.runAsync(() => db.customSelect('select 1').get());
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(ApiRepository(server.dio())),
      followsProvider.overrideWith((ref) => Stream.value({})),
      liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
    ],
  );
  _container = container;
  addTearDown(() => tester.runAsync(db.close));
  final router = GoRouter(
    initialLocation: '/match',
    routes: [
      GoRoute(
        path: '/match',
        builder: (_, _) => const MatchScreen(id: _match),
      ),
      GoRoute(
        path: '/player/:id',
        builder: (_, state) =>
            Scaffold(body: Text('Perfil ${state.pathParameters['id']}')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await _settle(tester);
  return server;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
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

Future<void> _tapPlayer(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    120,
    scrollable: find.byType(Scrollable).last,
  );
  // Centre it: the pinned tab bar must not cover the tap.
  await Scrollable.ensureVisible(tester.element(target), alignment: .5);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(target);
  await _settle(tester);
}

final _sheet = find.byKey(const ValueKey('player-sheet'));
final _profile = find.byKey(const ValueKey('player-sheet-profile'));
Finder _inSheet(Finder finder) => find.descendant(of: _sheet, matching: finder);

Future<void> _closeSheet(WidgetTester tester) async {
  // Tap the barrier above the sheet.
  await tester.tapAt(const Offset(20, 20));
  await _settle(tester);
}

void main() {
  group('playerMatchSummary', () {
    test('14. rating and real event counts only; zero counts omitted', () {
      final summary = playerMatchSummary(
        {'rating': 8.4},
        const [
          LineupPlayerEvent('GOAL', 23),
          LineupPlayerEvent('GOAL', 60),
          LineupPlayerEvent('YELLOW_CARD', 40),
          LineupPlayerEvent('SUB_OUT', 70, role: 'out'),
        ],
      );
      expect(summary.entries, [
        ('Rating', '8.4'),
        ('Goles', '2'),
        ('Amarillas', '1'),
      ]);
    });

    test('13. nothing real: no entries (no invented zeros)', () {
      expect(playerMatchSummary({'rating': null}, const []).entries, isEmpty);
      expect(playerMatchSummary({'rating': 0}, const []).entries, isEmpty);
    });
  });

  testWidgets('1/5/6/7/10. a starter opens the sheet with its real data', (
    tester,
  ) async {
    await _open(tester);
    await _tab(tester, 'Alineación');
    await _tapPlayer(tester, find.text('Nasibov').first);
    expect(_sheet, findsOneWidget);
    expect(find.text('Perfil fb_player_9'), findsNothing);
    expect(_inSheet(find.text('Nasibov')), findsOneWidget);
    expect(_inSheet(find.text('#9')), findsOneWidget);
    expect(_inSheet(find.text('Delantero')), findsOneWidget);
    expect(_inSheet(find.text('Local Panel')), findsOneWidget);
    expect(_inSheet(find.text('Capitán')), findsOneWidget);
    expect(_inSheet(find.text('27 años')), findsOneWidget);
    expect(
      _inSheet(find.byKey(const ValueKey('player-sheet-rating'))),
      findsOneWidget,
    );
    // No photo: the initials fallback, never a broken image or a spinner.
    expect(_inSheet(find.byType(Image)), findsNothing);
    expect(_inSheet(find.byType(CircularProgressIndicator)), findsNothing);
    // Real events of this player.
    for (final key in [
      'player-sheet-event-GOAL-23',
      'player-sheet-event-YELLOW_CARD-40',
      'player-sheet-event-SUB_OUT-70',
    ]) {
      expect(_inSheet(find.byKey(ValueKey(key))), findsOneWidget, reason: key);
    }
    expect(_profile, findsOneWidget);
    await _close(tester);
  });

  testWidgets('2/9. a bench player opens the same sheet; the assist provider '
      'without canonicalId has no Ver perfil', (tester) async {
    await _open(tester);
    await _tab(tester, 'Alineación');
    await _tapPlayer(tester, find.text('Suplente Panel'));
    expect(_sheet, findsOneWidget);
    expect(
      _inSheet(find.byKey(const ValueKey('player-sheet-event-SUB_IN-70'))),
      findsOneWidget,
    );
    expect(_profile, findsOneWidget);
    await _closeSheet(tester);

    await _tapPlayer(tester, find.text('Vagabov').first);
    expect(_sheet, findsOneWidget);
    expect(
      _inSheet(find.byKey(const ValueKey('player-sheet-event-ASSIST-23'))),
      findsOneWidget,
    );
    expect(_profile, findsNothing);
    expect(find.textContaining('Perfil'), findsNothing);
    await _close(tester);
  });

  testWidgets('3. Top Rated opens the sheet instead of navigating', (
    tester,
  ) async {
    await _open(tester);
    final card = find.byKey(const ValueKey('top-rated-card'));
    await _tapPlayer(
      tester,
      find.descendant(of: card, matching: find.text('Nasibov')),
    );
    expect(_sheet, findsOneWidget);
    expect(find.text('Perfil fb_player_9'), findsNothing);
    await _close(tester);
  });

  testWidgets('4. best rated by team opens the sheet', (tester) async {
    await _open(tester);
    await _tapPlayer(
      tester,
      find.byKey(const ValueKey('team-top-rated-home-0')),
    );
    expect(_sheet, findsOneWidget);
    expect(_inSheet(find.text('Nasibov')), findsOneWidget);
    await _close(tester);
  });

  testWidgets('8/13. a player with only a name: no fake placeholders, no '
      'summary, no events, no Ver perfil', (tester) async {
    await _open(
      tester,
      detail: _detail(
        starters: [_player('p77', 'Solonombre')],
        substitutes: const [],
      ),
    );
    await _tab(tester, 'Alineación');
    await _tapPlayer(tester, find.text('Solonombre').first);
    expect(_sheet, findsOneWidget);
    for (final key in [
      'player-sheet-number',
      'player-sheet-position',
      'player-sheet-captain',
      'player-sheet-age',
      'player-sheet-rating',
      'player-sheet-summary',
      'player-sheet-profile',
    ]) {
      expect(_inSheet(find.byKey(ValueKey(key))), findsNothing, reason: key);
    }
    expect(_inSheet(find.text('—')), findsNothing);
    expect(_inSheet(find.text('En el partido'.toUpperCase())), findsNothing);
    expect(_inSheet(find.text('Local Panel')), findsOneWidget);
    await _close(tester);
  });

  testWidgets('14. the summary groups the real rating and events', (
    tester,
  ) async {
    await _open(tester);
    await _tab(tester, 'Alineación');
    await _tapPlayer(tester, find.text('Nasibov').first);
    final summary = _inSheet(
      find.byKey(const ValueKey('player-sheet-summary')),
    );
    expect(summary, findsOneWidget);
    for (final text in ['Rating', '8.4', 'Gol', 'Amarillas']) {
      expect(
        find.descendant(of: summary, matching: find.text(text)),
        findsOneWidget,
        reason: text,
      );
    }
    expect(
      find.descendant(of: summary, matching: find.text('Asistencia')),
      findsNothing,
    );
    await _close(tester);
  });

  testWidgets('11. Ver perfil navigates to /player/<canonicalId>', (
    tester,
  ) async {
    await _open(tester);
    await _tab(tester, 'Alineación');
    await _tapPlayer(tester, find.text('Nasibov').first);
    await tester.tap(_profile);
    await tester.pumpAndSettle();
    expect(find.text('Perfil fb_player_9'), findsOneWidget);
    await _close(tester);
  });

  testWidgets('12/16. opening and closing is local: no detail read, same tab '
      'and scroll position', (tester) async {
    final server = await _open(tester);
    await _tab(tester, 'Alineación');
    final target = find.text('Suplente Panel');
    await tester.scrollUntilVisible(
      target,
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await _settle(tester);
    final controller = tester.widget<TabBar>(find.byType(TabBar)).controller!;
    final index = controller.index;
    final offset = tester
        .state<ScrollableState>(find.byType(Scrollable).last)
        .position
        .pixels;
    final reads = server.detailReads;
    await tester.tap(target);
    await _settle(tester);
    expect(_sheet, findsOneWidget);
    await _closeSheet(tester);
    expect(_sheet, findsNothing);
    expect(server.detailReads, reads, reason: 'no request to open/close');
    expect(controller.index, index);
    expect(
      tester
          .state<ScrollableState>(find.byType(Scrollable).last)
          .position
          .pixels,
      offset,
    );
    await _close(tester);
  });

  testWidgets('15. 360 px with a long name and every chip: no overflow', (
    tester,
  ) async {
    await _open(
      tester,
      width: 360,
      detail: _detail(
        starters: [
          _player(
            'p9',
            'Maximiliano Alejandro de la Santísima Trinidad',
            canonicalId: 'fb_player_9',
            number: '99',
            position: 'Midfielder',
            rating: 9.9,
            age: 34,
            captain: true,
          ),
        ],
        substitutes: const [],
      ),
    );
    await _tab(tester, 'Alineación');
    await _tapPlayer(tester, find.text('Trinidad').first);
    expect(_sheet, findsOneWidget);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });
}

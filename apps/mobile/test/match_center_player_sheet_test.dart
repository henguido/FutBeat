import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/entity_media.dart';
import 'package:futbeat/core/models.dart';
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
  Map<String, dynamic>? stats,
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
  'stats': ?stats,
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
  EntityMediaMemory? media,
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
      child: MaterialApp.router(
        routerConfig: router,
        builder: (_, child) => EntityMediaScope(
          memory: media ?? EntityMediaMemory(),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
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

    test('own goal belongs to its scorer but is not a regular goal', () {
      final events = lineupEventsForPlayer(
        {'id': 'home-player'},
        [
          {
            'type': 'GOAL',
            'side': 'away', // credited team, not the scorer's team
            'ownGoal': true,
            'playerId': 'home-player',
            'minute': 32,
          },
        ],
        'home',
      );
      expect(events.map((e) => e.type), ['OWN_GOAL']);
      expect(playerMatchSummary({}, events).entries, [('Autogol', '1')]);
      expect(
        lineupEventsForPlayer(
          {'id': 'home-player'},
          [
            {
              'type': 'GOAL',
              'side': null,
              'ownGoal': true,
              'playerId': 'home-player',
            },
          ],
          'home',
        ).map((e) => e.type),
        ['OWN_GOAL'],
      );
      expect(
        lineupEventsForPlayer(
          {'id': 'home-player'},
          [
            {'type': 'GOAL', 'side': 'away', 'playerId': 'home-player'},
          ],
          'home',
        ),
        isEmpty,
      );
    });

    test('only a regular goal can credit an assist', () {
      final events = lineupEventsForPlayer(
        {'id': 'assister'},
        [
          {'type': 'VAR', 'side': 'home', 'assistPlayerId': 'assister'},
          {
            'type': 'GOAL',
            'side': 'home',
            'ownGoal': true,
            'assistPlayerId': 'assister',
          },
          {'type': 'GOAL', 'side': 'home', 'assistPlayerId': 'assister'},
        ],
        'home',
      );
      expect(events.map((e) => e.type), ['ASSIST']);
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
    // Real events of this player (the summary grew: expand the sheet).
    await tester.drag(
      find.byKey(const ValueKey('player-sheet-name')),
      const Offset(0, -500),
    );
    await _settle(tester);
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

  group('playerMinutesPlayed (only event-anchored stints)', () {
    MatchDetail detail(List<Map<String, dynamic>> incidents) =>
        MatchDetail(_detail()..['incidents'] = incidents);
    final starter = {'id': 'p9'};
    final bench = {'id': 'p12'};
    Map<String, dynamic> sub(int minute, String out, String into) => {
      'type': 'SUBSTITUTION',
      'minute': minute,
      'side': 'home',
      'outPlayerId': out,
      'inPlayerId': into,
    };
    Map<String, dynamic> red(int minute, String id) => {
      'type': 'RED_CARD',
      'minute': minute,
      'side': 'home',
      'playerId': id,
    };

    test('starter taken off: entry 0, exit at the substitution', () {
      expect(
        playerMinutesPlayed(starter, detail([sub(70, 'p9', 'p12')]), 'home'),
        70,
      );
    });

    test('sub who stayed on, or starter never off: unknown end, null', () {
      final d = detail([sub(70, 'p9', 'p12')]);
      expect(playerMinutesPlayed(bench, d, 'home'), isNull);
      expect(playerMinutesPlayed({'id': 'p10'}, d, 'home'), isNull);
    });

    test('substitute on and off again: exit minus entry', () {
      expect(
        playerMinutesPlayed(
          bench,
          detail([sub(60, 'p9', 'p12'), sub(85, 'p12', 'p10')]),
          'home',
        ),
        25,
      );
    });

    test('red card ends the stint', () {
      expect(playerMinutesPlayed(starter, detail([red(40, 'p9')]), 'home'), 40);
    });

    test('re-issued substitution (same minute) counts once; conflicting '
        'minutes are ambiguous', () {
      expect(
        playerMinutesPlayed(
          starter,
          detail([sub(70, 'p9', 'p12'), sub(70, 'p9', 'p12')]),
          'home',
        ),
        70,
      );
      expect(
        playerMinutesPlayed(
          starter,
          detail([sub(70, 'p9', 'p12'), sub(75, 'p9', 'p12')]),
          'home',
        ),
        isNull,
      );
    });

    test('other side, unknown id, unlisted player, stoppage-time stint', () {
      final d = detail([sub(70, 'p9', 'p12')]);
      expect(playerMinutesPlayed(starter, d, 'away'), isNull);
      expect(playerMinutesPlayed({'id': ''}, d, 'home'), isNull);
      expect(playerMinutesPlayed({'id': 'ghost'}, d, 'home'), isNull);
      // On at 90 and sent off at 90: on the pitch, never "0".
      expect(
        playerMinutesPlayed(
          bench,
          detail([sub(90, 'p9', 'p12'), red(90, 'p12')]),
          'home',
        ),
        1,
      );
    });
  });

  group('playerMatchStatSections (provider stats contract)', () {
    test('no stats map: no sections', () {
      expect(playerMatchStatSections({'name': 'X'}), isEmpty);
      expect(playerMatchStatSections({'stats': 'nope'}), isEmpty);
    });

    test('only present keys, grouped; empty groups hidden', () {
      final sections = playerMatchStatSections({
        'stats': {
          'touches': 54,
          'accuratePasses': '21/25',
          'tackles': 3,
          'crosses': null,
          'longBalls': '',
          'blocks': '-',
          'unknownKey': 9,
        },
      });
      expect(
        sections.map((s) => (s.$1, [...s.$2])).toList().toString(),
        [
          ('Con balón', [('Toques', '54')]),
          ('Pases', [('Pases precisos', '21/25')]),
          ('Defensa', [('Entradas', '3')]),
        ].toString(),
      );
    });

    test('an all-zero block is no coverage, never a wall of zeros', () {
      expect(
        playerMatchStatSections({
          'stats': {'touches': 0, 'tackles': 0, 'accuratePasses': '0/0'},
        }),
        isEmpty,
      );
    });
  });

  testWidgets('minutes: a starter taken off shows real minutes; a sub who '
      'stayed on shows none', (tester) async {
    await _open(tester);
    await _tab(tester, 'Alineación');
    await _tapPlayer(tester, find.text('Nasibov').first);
    final summary = _inSheet(
      find.byKey(const ValueKey('player-sheet-summary')),
    );
    expect(
      find.descendant(of: summary, matching: find.text('Minutos')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: summary, matching: find.text('70′')),
      findsOneWidget,
    );
    await _closeSheet(tester);

    await _tapPlayer(tester, find.text('Suplente Panel'));
    expect(_sheet, findsOneWidget);
    expect(_inSheet(find.text('Minutos')), findsNothing);
    expect(_inSheet(find.text('0′')), findsNothing);
    await _close(tester);
  });

  testWidgets('an own goal is visible on the scorer sheet, never as a goal', (
    tester,
  ) async {
    await _open(
      tester,
      detail:
          _detail(
              starters: [_player('p9', 'Defensor Local', position: 'Defender')],
              substitutes: const [],
            )
            ..['incidents'] = [
              {
                'type': 'GOAL',
                'side': 'away',
                'ownGoal': true,
                'playerId': 'p9',
                'minute': 32,
              },
            ],
    );
    await _tab(tester, 'Alineación');
    await _tapPlayer(tester, find.text('Local').first);
    expect(_inSheet(find.text('Autogol')), findsWidgets);
    expect(_inSheet(find.text('Gol')), findsNothing);
    expect(
      _inSheet(find.byKey(const ValueKey('player-sheet-event-OWN_GOAL-32'))),
      findsOneWidget,
    );
    await _close(tester);
  });

  testWidgets('team crest beside the team name; single-letter position is '
      'readable', (tester) async {
    await _open(
      tester,
      detail: _detail(
        starters: [_player('p1', 'Arquero Panel', position: 'G')],
        substitutes: const [],
      ),
    );
    await _tab(tester, 'Alineación');
    await _tapPlayer(tester, find.text('Panel').first);
    final team = _inSheet(find.byKey(const ValueKey('player-sheet-team')));
    expect(team, findsOneWidget);
    expect(
      find.descendant(
        of: team,
        matching: find.byKey(const ValueKey('player-sheet-team-crest')),
      ),
      findsOneWidget,
    );
    expect(_inSheet(find.text('Portero')), findsOneWidget);
    await _close(tester);
  });

  testWidgets('photo comes from the shared resolver for the canonical '
      'identity (same photo as the profile)', (tester) async {
    final media = EntityMediaMemory()
      ..absorb(
        Snapshot({
          'schemaVersion': 1,
          'demo': false,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'teams': const <dynamic>[],
          'competitions': const <dynamic>[],
          'matches': const <dynamic>[],
          'standings': const <dynamic>[],
          'players': [
            {
              'id': 'fb_player_9',
              'name': 'Nasibov',
              'media': {
                'url': 'https://media.example.com/p9.png',
                'verificationStatus': 'VERIFIED',
              },
            },
          ],
        }),
      );
    await _open(tester, media: media);
    await _tab(tester, 'Alineación');
    await _tapPlayer(tester, find.text('Nasibov').first);
    final images = tester.widgetList<Image>(_inSheet(find.byType(Image)));
    expect(
      images.map((image) {
        final provider = image.image;
        final network = provider is ResizeImage
            ? provider.imageProvider
            : provider;
        return (network as NetworkImage).url;
      }),
      contains('https://media.example.com/p9.png'),
    );
    await _close(tester);
  });

  testWidgets('provider stats render in groups only when present; absent '
      'groups are hidden', (tester) async {
    await _open(
      tester,
      detail: _detail(
        starters: [
          _player(
            'p9',
            'Nasibov',
            canonicalId: 'fb_player_9',
            stats: {'touches': 54, 'accuratePasses': '21/25'},
          ),
        ],
        substitutes: const [],
      ),
    );
    await _tab(tester, 'Alineación');
    await _tapPlayer(tester, find.text('Nasibov').first);
    expect(
      _inSheet(find.byKey(const ValueKey('player-sheet-stats-Con balón'))),
      findsOneWidget,
    );
    expect(
      _inSheet(find.byKey(const ValueKey('player-sheet-stats-Pases'))),
      findsOneWidget,
    );
    for (final hidden in ['Defensa', 'Disciplina']) {
      expect(
        _inSheet(find.byKey(ValueKey('player-sheet-stats-$hidden'))),
        findsNothing,
        reason: hidden,
      );
    }
    expect(_inSheet(find.text('54')), findsOneWidget);
    expect(_inSheet(find.text('21/25')), findsOneWidget);
    expect(_inSheet(find.text('Entradas')), findsNothing);
    await _close(tester);
  });
}

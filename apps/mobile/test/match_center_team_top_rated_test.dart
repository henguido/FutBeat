import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/match_screen.dart';
import 'package:go_router/go_router.dart';

// #99 "Mejor puntuado por equipo": the best real lineup rating of each side.
// Ties stay ties, a side without ratings stays empty, nothing is invented.

const _match = 'fb_match_ttr';
const _home = 'fb_team_ttr_home';
const _away = 'fb_team_ttr_away';

Map<String, dynamic> _snapshot({String status = 'VERIFIED'}) {
  final now = DateTime.now().toUtc();
  final kickoff = status == 'SCHEDULED'
      ? now.add(const Duration(days: 1))
      : now.subtract(const Duration(hours: 3));
  return {
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': now.toIso8601String(),
    'coverage': {'standings': 'missing', 'standingsPending': false},
    'competitions': [
      {'id': 'fb_comp_ttr', 'name': 'Liga Equipos'},
    ],
    'teams': [
      {'id': _home, 'name': 'Local Equipos'},
      {'id': _away, 'name': 'Visita Equipos'},
    ],
    'players': <dynamic>[],
    'standings': <dynamic>[],
    'matches': [
      {
        'id': _match,
        'competitionId': 'fb_comp_ttr',
        'homeTeamId': _home,
        'awayTeamId': _away,
        'startTime': kickoff.toIso8601String(),
        'status': status,
        'season': '2026',
        if (status != 'SCHEDULED') 'score': {'home': 1, 'away': 1},
        if (status == 'LIVE') ...{
          'minute': 60,
          'liveChangedAt': now.toIso8601String(),
        },
        'events': const <dynamic>[],
        'statistics': const <dynamic>[],
      },
    ],
  };
}

Map<String, dynamic> _player(
  String name,
  num? rating, {
  String? canonicalId,
  String? position = 'Forward',
}) => {
  'id': 'ext-$name',
  'canonicalId': canonicalId,
  'name': name,
  'number': '9',
  'position': position,
  'lineupPosition': 1,
  'rating': rating,
};

Map<String, dynamic> _detail({
  List<Map<String, dynamic>> home = const [],
  List<Map<String, dynamic>> away = const [],
  List<Map<String, dynamic>> homeSubs = const [],
  List<Map<String, dynamic>> awaySubs = const [],
}) => {
  'matchId': _match,
  'available': true,
  'pending': false,
  'hydrationNeeded': false,
  'detailLevel': 'full',
  'home': {'formation': '4-3-3', 'starters': home, 'substitutes': homeSubs},
  'away': {'formation': '4-3-3', 'starters': away, 'substitutes': awaySubs},
  'statistics': const <dynamic>[],
  'incidents': const <dynamic>[],
  'videos': const <dynamic>[],
};

List<String?> _names(List<Json> players) =>
    players.map((player) => player['name'] as String?).toList();

Future<void> _open(
  WidgetTester tester,
  Map<String, dynamic> detail, {
  String status = 'VERIFIED',
  double width = 390,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final db = AppDatabase(NativeDatabase.memory());
  await tester.runAsync(() => db.customSelect('select 1').get());
  final payload = _snapshot(status: status);
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(ApiRepository(Dio())),
      matchContextSnapshotProvider.overrideWith(
        (ref, id) async => Snapshot(payload),
      ),
      matchDetailProvider.overrideWith(
        (ref, id) => Stream.value(MatchDetail(detail)),
      ),
      followsProvider.overrideWith((ref) => Stream.value({})),
      liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.runAsync(db.close);
  });
  final router = GoRouter(
    initialLocation: '/match',
    routes: [
      GoRoute(
        path: '/match',
        builder: (_, _) =>
            MatchScreen(id: _match, initialData: Snapshot(payload)),
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
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    150,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.pump(const Duration(milliseconds: 100));
}

const _card = ValueKey('team-top-rated-card');

void main() {
  group('MatchDetail.bestRatedBySide', () {
    test('A. highest per side: A and C', () {
      final best = MatchDetail(
        _detail(
          home: [_player('A', 8.5), _player('B', 7.2)],
          away: [_player('C', 8.1), _player('D', 7.0)],
        ),
      ).bestRatedBySide();
      expect(_names(best.home), ['A']);
      expect(_names(best.away), ['C']);
    });

    test('B. exact tie at the top of a side: both, as equals', () {
      final best = MatchDetail(
        _detail(home: [_player('B', 8.5), _player('A', 8.5), _player('Z', 6)]),
      ).bestRatedBySide();
      expect(_names(best.home), ['A', 'B']);
      expect(best.away, isEmpty);
    });

    test('C. same canonical player as starter and substitute: once', () {
      final best = MatchDetail(
        _detail(
          home: [_player('Uno', 8.0, canonicalId: 'fb_player_1')],
          homeSubs: [_player('Uno bis', 8.0, canonicalId: 'fb_player_1')],
        ),
      ).bestRatedBySide();
      expect(best.home, hasLength(1));
    });

    test('C2. without canonicalId: deduplicated by name + side only', () {
      final best = MatchDetail(
        _detail(
          home: [_player('Mismo', 7.5)],
          homeSubs: [_player('Mismo', 7.5)],
          away: [_player('Mismo', 7.5)],
        ),
      ).bestRatedBySide();
      expect(_names(best.home), ['Mismo']);
      expect(_names(best.away), ['Mismo']);
    });

    test('D. null, 0 and negative ratings are ignored', () {
      final best = MatchDetail(
        _detail(
          home: [_player('N', null), _player('Z', 0), _player('M', -1)],
          away: [_player('Ok', 6.1), _player('Neg', -3)],
        ),
      ).bestRatedBySide();
      expect(best.home, isEmpty);
      expect(_names(best.away), ['Ok']);
    });

    test('global topRated is unchanged by the refactor', () {
      final detail = MatchDetail(
        _detail(
          home: [_player('A', 8.5), _player('B', 7.2)],
          away: [_player('C', 8.1)],
        ),
      );
      expect(_names([for (final e in detail.topRated()) e.player]), [
        'A',
        'C',
        'B',
      ]);
      expect(detail.playerOfTheMatch?.player['name'], 'A');
    });
  });

  group('Match Center block', () {
    testWidgets('1/9. FT: best of each side, position shown, no Provisional', (
      tester,
    ) async {
      await _open(
        tester,
        _detail(
          home: [_player('Local Mejor', 8.4), _player('Local B', 7.0)],
          away: [
            _player('Visita Mejor', 7.9, position: 'Defender'),
            _player('Visita B', 6.5),
          ],
        ),
      );
      await _scrollTo(tester, find.byKey(_card));
      final card = find.byKey(_card);
      expect(find.text('Mejor puntuado por equipo'), findsOneWidget);
      expect(
        find.descendant(of: card, matching: find.text('Local Mejor')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('Visita Mejor')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('Local B')),
        findsNothing,
      );
      expect(
        find.descendant(of: card, matching: find.text('Delantero')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('Defensa')),
        findsOneWidget,
      );
      expect(find.text('Provisional'), findsNothing);
    });

    testWidgets('2. LIVE marks the block as Provisional', (tester) async {
      await _open(
        tester,
        _detail(home: [_player('Vivo', 7.1)], away: [_player('Otro', 6.9)]),
        status: 'LIVE',
      );
      await _scrollTo(tester, find.byKey(_card));
      // This block carries its own marker, between its title and its card.
      final title = tester
          .getTopLeft(find.text('Mejor puntuado por equipo'))
          .dy;
      final card = tester.getTopLeft(find.byKey(_card)).dy;
      final markers = find
          .text('Provisional')
          .evaluate()
          .map(
            (e) => (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dy,
          )
          .where((dy) => dy > title && dy < card);
      expect(markers, hasLength(1));
    });

    testWidgets('3. SCHEDULED: no block', (tester) async {
      await _open(
        tester,
        _detail(home: [_player('Antes', 7.1)]),
        status: 'SCHEDULED',
      );
      expect(find.byKey(_card), findsNothing);
      expect(find.text('Mejor puntuado por equipo'), findsNothing);
    });

    testWidgets('4. no ratings: no block', (tester) async {
      await _open(
        tester,
        _detail(home: [_player('Sin', null)], away: [_player('Nada', 0)]),
      );
      expect(find.byKey(_card), findsNothing);
      expect(find.text('Mejor puntuado por equipo'), findsNothing);
    });

    testWidgets('5. only home rated: only the home side, no placeholder', (
      tester,
    ) async {
      await _open(
        tester,
        _detail(home: [_player('Solo Local', 7.3)], away: [_player('X', null)]),
      );
      await _scrollTo(tester, find.byKey(_card));
      expect(
        find.byKey(const ValueKey('team-top-rated-home-0')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('team-top-rated-away-0')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(_card),
          matching: find.text('Visita Equipos'),
        ),
        findsNothing,
      );
    });

    testWidgets('6. a tie is shown as a tie, never one arbitrary winner', (
      tester,
    ) async {
      await _open(
        tester,
        _detail(
          home: [_player('Empate Uno', 8.5), _player('Empate Dos', 8.5)],
          away: [_player('Único', 7.0)],
        ),
      );
      await _scrollTo(tester, find.byKey(_card));
      expect(
        find.byKey(const ValueKey('team-top-rated-home-tie')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('team-top-rated-home-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('team-top-rated-home-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('team-top-rated-away-tie')),
        findsNothing,
      );
    });

    testWidgets('10. missing position does not break the row', (tester) async {
      await _open(
        tester,
        _detail(home: [_player('Sin Posición', 7.7, position: null)]),
      );
      await _scrollTo(tester, find.byKey(_card));
      expect(
        find.descendant(
          of: find.byKey(_card),
          matching: find.text('Sin Posición'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('11. canonicalId opens the player profile', (tester) async {
      await _open(
        tester,
        _detail(home: [_player('Con Perfil', 8.0, canonicalId: 'fb_player_9')]),
      );
      final row = find.byKey(const ValueKey('team-top-rated-home-0'));
      await _scrollTo(tester, row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.text('Perfil fb_player_9'), findsOneWidget);
    });

    testWidgets('12. very long names at 360 px: ellipsis, no overflow', (
      tester,
    ) async {
      await _open(
        tester,
        _detail(
          home: [
            _player('Maximiliano Alejandro de la Santísima Trinidad', 8.2),
          ],
          away: [
            _player(
              'Constantinos Papadopoulos-Economou Wolfeschlegelstein',
              7.8,
              position: 'Midfielder',
            ),
          ],
        ),
        width: 360,
      );
      await _scrollTo(tester, find.byKey(_card));
      expect(tester.takeException(), isNull);
    });
  });
}

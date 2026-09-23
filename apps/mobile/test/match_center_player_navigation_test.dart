import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/match_screen.dart';

// Image.network with a cacheWidth/cacheHeight wraps the NetworkImage in a
// ResizeImage, so the URL must be unwrapped rather than read directly.
String? _networkUrl(ImageProvider? provider) {
  var resolved = provider;
  if (resolved is ResizeImage) resolved = resolved.imageProvider;
  return resolved is NetworkImage ? resolved.url : null;
}

Map<String, dynamic> _payload() => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-09-23T12:00:00Z',
  'competitions': [
    {'id': 'fb_comp', 'name': 'Liga de Prueba'},
  ],
  'teams': [
    {'id': 'fb_home', 'name': 'Local FC'},
    {'id': 'fb_away', 'name': 'Visita FC'},
  ],
  'players': [],
  'standings': [],
  'matches': [
    {
      'id': 'fb_match',
      'competitionId': 'fb_comp',
      'homeTeamId': 'fb_home',
      'awayTeamId': 'fb_away',
      'startTime': DateTime.utc(2026, 9, 20, 18).toIso8601String(),
      'status': 'VERIFIED',
      'score': {'home': 1, 'away': 0},
      'events': const [],
      'statistics': const [],
    },
  ],
};

Map<String, dynamic> _lineupPlayer({
  required String name,
  String? canonicalId,
  String? image,
  int lineupPosition = 1,
}) => {
  'id': 'ext-$name',
  'canonicalId': canonicalId,
  'name': name,
  'number': '9',
  'position': 'Forward',
  'lineupPosition': lineupPosition,
  'image': image,
};

Map<String, dynamic> _detail({
  required Map<String, dynamic> starter,
  required Map<String, dynamic> bench,
}) => {
  'matchId': 'fb_match',
  'available': true,
  'pending': false,
  'detailLevel': 'full',
  'home': {
    'formation': '4-3-3',
    'starters': [starter],
    'substitutes': [bench],
  },
  'away': <String, dynamic>{},
  'statistics': const [],
  'incidents': const [],
};

Future<void> _pumpMatch(WidgetTester tester, Map<String, dynamic> detail) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final db = AppDatabase(NativeDatabase.memory());
  final payload = _payload();
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(ApiRepository(Dio())),
      matchContextSnapshotProvider.overrideWith((ref, id) async => Snapshot(payload)),
      matchDetailProvider.overrideWith((ref, id) => Stream.value(MatchDetail(detail))),
      followsProvider.overrideWith((ref) => Stream.value({})),
      liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.runAsync(db.close);
  });
  // context.push('/player/<id>') needs a real GoRouter ancestor (GoRouterHelper
  // looks up GoRouter.of(context)); a bare MaterialApp/onGenerateRoute does not
  // provide one.
  final router = GoRouter(
    initialLocation: '/match',
    routes: [
      GoRoute(
        path: '/match',
        builder: (_, _) => MatchScreen(id: 'fb_match', initialData: Snapshot(payload)),
      ),
      GoRoute(
        path: '/player/:id',
        builder: (_, _) => const Scaffold(body: Text('Player profile route')),
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
  await tester.pumpAndSettle();
  // Lineups render under the "Alineación" tab, not the default summary tab.
  await tester.ensureVisible(find.text('Alineación'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Alineación'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('starter with canonicalId and canonical photo: tappable, photo renders (cases B1/D1)', (tester) async {
    await _pumpMatch(
      tester,
      _detail(
        starter: _lineupPlayer(name: 'Goleador', canonicalId: 'fb_player_1',
          image: 'https://media.goal-api.com/players/1.png'),
        bench: _lineupPlayer(name: 'Suplente', canonicalId: 'fb_player_2', lineupPosition: 2),
      ),
    );
    expect(
      find.byWidgetPredicate((w) => w is Image && (_networkUrl(w.image) ?? '').endsWith('1.png')),
      findsOneWidget,
    );
    final starterInkWell = find.ancestor(of: find.text('Goleador'), matching: find.byType(InkWell)).first;
    expect(starterInkWell, findsOneWidget);
  });

  testWidgets('bench player with canonical photo renders it (case D2)', (tester) async {
    await _pumpMatch(
      tester,
      _detail(
        starter: _lineupPlayer(name: 'Titular', canonicalId: 'fb_player_1'),
        bench: _lineupPlayer(name: 'Con Foto', canonicalId: 'fb_player_2', lineupPosition: 2,
          image: 'https://media.goal-api.com/players/2.png'),
      ),
    );
    expect(
      find.byWidgetPredicate((w) => w is Image && (_networkUrl(w.image) ?? '').endsWith('2.png')),
      findsOneWidget,
    );
  });

  testWidgets('player without any photo shows initials, not a broken image (case D4)', (tester) async {
    await _pumpMatch(
      tester,
      _detail(
        starter: _lineupPlayer(name: 'Sin Foto', canonicalId: 'fb_player_1'),
        bench: _lineupPlayer(name: 'Suplente', canonicalId: 'fb_player_2', lineupPosition: 2),
      ),
    );
    expect(find.text('SF'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('tapping a starter with canonicalId navigates to /player/<canonicalId> (case C, F)', (tester) async {
    await _pumpMatch(
      tester,
      _detail(
        starter: _lineupPlayer(name: 'Goleador', canonicalId: 'fb_player_1'),
        bench: _lineupPlayer(name: 'Suplente', canonicalId: 'fb_player_2', lineupPosition: 2),
      ),
    );
    await tester.tap(find.text('Goleador'));
    await tester.pumpAndSettle();
    expect(find.text('Player profile route'), findsOneWidget);
  });

  testWidgets('tapping a bench player with canonicalId navigates to /player/<canonicalId> (case C, F)', (tester) async {
    await _pumpMatch(
      tester,
      _detail(
        starter: _lineupPlayer(name: 'Titular', canonicalId: 'fb_player_1'),
        bench: _lineupPlayer(name: 'Suplente', canonicalId: 'fb_player_2', lineupPosition: 2),
      ),
    );
    await tester.tap(find.text('Suplente'));
    await tester.pumpAndSettle();
    expect(find.text('Player profile route'), findsOneWidget);
  });

  testWidgets('player without canonicalId yet: not tappable, no crash, presentation unchanged (review focus)', (tester) async {
    await _pumpMatch(
      tester,
      _detail(
        starter: _lineupPlayer(name: 'Pendiente', canonicalId: null),
        bench: _lineupPlayer(name: 'Suplente', canonicalId: 'fb_player_2', lineupPosition: 2),
      ),
    );
    expect(find.text('Pendiente'), findsOneWidget);
    final pendienteInkWell = find.ancestor(of: find.text('Pendiente'), matching: find.byType(InkWell));
    expect(pendienteInkWell, findsNothing);
    await tester.tap(find.text('Pendiente'));
    await tester.pumpAndSettle();
    expect(find.text('Player profile route'), findsNothing);
  });

  // Two separate tests, not a loop over one testWidgets body: _pumpMatch
  // creates its own ProviderContainer/database and registers its own
  // addTearDown per call, and those only run at the end of the whole test —
  // calling it twice in one test leaves the first container's riverpod
  // dispose-scheduling timer pending when the second pumpWidget replaces the
  // tree, which flutter_test flags as a leaked timer.
  for (final width in [320.0, 360.0]) {
    testWidgets('renders at ${width.toInt()}px without overflow (case F)', (tester) async {
      tester.view.physicalSize = Size(width, 780);
      tester.view.devicePixelRatio = 1;
      await _pumpMatch(
        tester,
        _detail(
          starter: _lineupPlayer(name: 'Goleador con Nombre Largo', canonicalId: 'fb_player_1'),
          bench: _lineupPlayer(name: 'Suplente', canonicalId: 'fb_player_2', lineupPosition: 2),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  }
}

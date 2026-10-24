import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/theme.dart';
import 'package:futbeat/features/favorites/favorites_screen.dart';
import 'package:futbeat/features/matches/matches_screen.dart';
import 'package:go_router/go_router.dart';

Map<String, dynamic> _payload({bool aliases = false}) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-10-07T12:00:00Z',
  if (aliases) 'entityRedirects': {'team_alias': 'team_a'},
  'competitions': [
    {'id': 'comp_a', 'name': 'Liga Nacional', 'country': 'Costa Rica'},
  ],
  'teams': [
    {
      'id': 'team_a',
      'name': 'Asociación Deportiva de Nombre Extraordinariamente Largo',
      'country': 'Costa Rica',
      'competitionId': 'comp_a',
    },
    if (aliases) {'id': 'team_alias', 'name': 'Nombre antiguo'},
    {'id': 'team_b', 'name': 'Rival FC', 'country': 'Costa Rica'},
  ],
  'players': [
    {
      'id': 'player_a',
      'name': 'Delantero Seguido',
      'teamId': 'team_a',
      'position': 'Forward',
    },
  ],
  'matches': [
    {
      'id': 'match_a',
      'competitionId': 'comp_a',
      'homeTeamId': 'team_a',
      'awayTeamId': 'team_b',
      'startTime': '2099-10-20T18:00:00Z',
      'status': 'SCHEDULED',
      'events': <dynamic>[],
      'statistics': <dynamic>[],
    },
  ],
  'standings': <dynamic>[],
};

class _Harness {
  _Harness(this.db, this.container, this.router, this.requests);
  final AppDatabase db;
  final ProviderContainer container;
  final GoRouter router;
  final List<String> requests;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  Set<String> follows = const {
    'team:team_a',
    'player:player_a',
    'competition:comp_a',
  },
  Size size = const Size(390, 844),
  bool aliases = false,
  Future<Snapshot> Function(String keys, int request)? snapshotLoader,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final db = AppDatabase(NativeDatabase.memory());
  await tester.runAsync(() => db.addFollows(follows));
  final requests = <String>[];
  var requestNumber = 0;
  final router = GoRouter(
    initialLocation: '/favorites',
    routes: [
      GoRoute(path: '/favorites', builder: (_, _) => const FavoritesScreen()),
      for (final type in ['team', 'player', 'competition'])
        GoRoute(
          path: '/$type/:id',
          builder: (_, state) =>
              Scaffold(body: Text('$type:${state.pathParameters['id']}')),
        ),
      GoRoute(
        path: '/explore',
        builder: (_, _) => const Scaffold(body: Text('Explorar destino')),
      ),
    ],
  );
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      favoritesSnapshotProvider.overrideWith((ref, keys) async {
        requests.add(keys);
        requestNumber += 1;
        if (snapshotLoader != null) {
          return snapshotLoader(keys, requestNumber);
        }
        return Snapshot(_payload(aliases: aliases));
      }),
      liveMatchUpdatesProvider.overrideWith(
        (ref) => Stream.value(const <String, LiveMatchUpdate>{}),
      ),
    ],
  );
  if (aliases) {
    container
        .read(entityMediaProvider)
        .absorb(Snapshot(_payload(aliases: true)));
  }
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    router.dispose();
    container.dispose();
    await tester.runAsync(db.close);
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(theme: futbeatTheme(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(db, container, router, requests);
}

Future<void> _tab(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  test('hub data is canonical, deduplicated and alphabetically stable', () {
    final data = Snapshot(_payload(aliases: true));
    final hub = FollowingHubData.from(data, const {'team:team_alias'});
    expect(hub.teams.map((entity) => entity.id), ['team_a']);
  });

  testWidgets('mixed follows have counts, tabs and useful compact metadata', (
    tester,
  ) async {
    final harness = await _pump(tester, size: const Size(320, 760));
    expect(find.text('1 equipos · 1 jugadores · 1 competiciones'), findsOne);
    expect(find.text('Equipos'), findsOneWidget);
    expect(find.text('Jugadores'), findsOneWidget);
    expect(find.text('Competiciones'), findsOneWidget);
    expect(find.text('Costa Rica · Liga Nacional'), findsOneWidget);
    expect(find.text('Próximo · vs Rival FC'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _tab(tester, 'Jugadores');
    expect(find.text('Delantero Seguido'), findsOneWidget);
    expect(find.textContaining('Rival'), findsNothing);
    expect(
      find.text(
        'Asociación Deportiva de Nombre Extraordinariamente Largo · Delantero',
      ),
      findsOneWidget,
    );
    await _tab(tester, 'Competiciones');
    expect(find.text('Liga Nacional'), findsOneWidget);
    expect(harness.requests, hasLength(1), reason: 'tabs reuse one snapshot');
  });

  testWidgets('each empty section has its own Explore action', (tester) async {
    await _pump(tester, follows: const {'team:team_a'});
    await _tab(tester, 'Jugadores');
    expect(find.text('Aún no sigues jugadores.'), findsOneWidget);
    await _tab(tester, 'Competiciones');
    expect(find.text('Aún no sigues competiciones.'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('following-explore-competition')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Explorar destino'), findsOneWidget);
  });

  testWidgets('unfollow updates the visible section immediately', (
    tester,
  ) async {
    final harness = await _pump(tester, follows: const {'team:team_a'});
    await tester.tap(
      find.byTooltip(
        'Dejar de seguir Asociación Deportiva de Nombre Extraordinariamente Largo',
      ),
    );
    await tester.runAsync(
      () => harness.db.watchFollows().firstWhere((value) => value.isEmpty),
    );
    await tester.pumpAndSettle();
    expect(find.text('Aún no sigues equipos.'), findsOneWidget);
    expect(find.text('0 equipos · 0 jugadores · 0 competiciones'), findsOne);
  });

  testWidgets('a refresh error keeps the last successful snapshot visible', (
    tester,
  ) async {
    final harness = await _pump(
      tester,
      snapshotLoader: (_, request) async {
        if (request > 1) throw StateError('offline');
        return Snapshot(_payload());
      },
    );
    expect(
      find.text('Asociación Deportiva de Nombre Extraordinariamente Largo'),
      findsOneWidget,
    );

    harness.container.invalidate(
      favoritesSnapshotProvider(
        'competition:comp_a,player:player_a,team:team_a',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Mostrando tus seguidos guardados'), findsOneWidget);
    expect(
      find.text('Asociación Deportiva de Nombre Extraordinariamente Largo'),
      findsOneWidget,
    );
  });

  for (final target in const [
    (tab: 'Equipos', type: 'team', id: 'team_a'),
    (tab: 'Jugadores', type: 'player', id: 'player_a'),
    (tab: 'Competiciones', type: 'competition', id: 'comp_a'),
  ]) {
    testWidgets('${target.tab} opens the existing profile route', (
      tester,
    ) async {
      await _pump(tester);
      if (target.tab != 'Equipos') await _tab(tester, target.tab);
      await tester.tap(
        find.byKey(ValueKey('following-${target.type}-${target.id}')),
      );
      await tester.pumpAndSettle();
      expect(find.text('${target.type}:${target.id}'), findsOneWidget);
    });
  }

  for (final width in [320.0, 360.0, 390.0]) {
    testWidgets('hub remains usable at ${width.toInt()} px', (tester) async {
      await _pump(tester, size: Size(width, 760));
      for (final tab in ['Jugadores', 'Competiciones', 'Equipos']) {
        await _tab(tester, tab);
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('guest with no follows gets three independent empty sections', (
    tester,
  ) async {
    await _pump(tester, follows: const {});
    expect(find.text('Aún no sigues equipos.'), findsOneWidget);
    await _tab(tester, 'Jugadores');
    expect(find.text('Aún no sigues jugadores.'), findsOneWidget);
    await _tab(tester, 'Competiciones');
    expect(find.text('Aún no sigues competiciones.'), findsOneWidget);
  });

  testWidgets('sync loading yields to local follows when they arrive', (
    tester,
  ) async {
    final follows = StreamController<Set<String>>();
    addTearDown(follows.close);
    final container = ProviderContainer(
      overrides: [
        followsProvider.overrideWith((ref) => follows.stream),
        favoritesSnapshotProvider.overrideWith(
          (ref, keys) async => Snapshot(_payload()),
        ),
        liveMatchUpdatesProvider.overrideWith(
          (ref) => Stream.value(const <String, LiveMatchUpdate>{}),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: futbeatTheme(),
          home: const FavoritesScreen(),
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    follows.add(const {'team:team_a'});
    await tester.pumpAndSettle();
    expect(
      find.text('Asociación Deportiva de Nombre Extraordinariamente Largo'),
      findsOneWidget,
    );
  });

  testWidgets('goldens for mixed hub and entity tabs', (tester) async {
    await _pump(tester);
    await expectLater(
      find.byType(FavoritesScreen),
      matchesGoldenFile('goldens/favorites_hub_mixed.png'),
    );
    await expectLater(
      find.byType(FavoritesScreen),
      matchesGoldenFile('goldens/favorites_hub_teams.png'),
    );
    await _tab(tester, 'Jugadores');
    await expectLater(
      find.byType(FavoritesScreen),
      matchesGoldenFile('goldens/favorites_hub_players.png'),
    );
    await _tab(tester, 'Competiciones');
    await expectLater(
      find.byType(FavoritesScreen),
      matchesGoldenFile('goldens/favorites_hub_competitions.png'),
    );
  }, tags: 'golden');

  testWidgets('golden for empty hub', (tester) async {
    await _pump(tester, follows: const {});
    await expectLater(
      find.byType(FavoritesScreen),
      matchesGoldenFile('goldens/favorites_hub_empty.png'),
    );
  }, tags: 'golden');

  test('Partidos Favoritos accepts teams only', () {
    final match = FootballMatch((_payload()['matches'] as List).single);
    expect(isFollowedTeamMatch(match, const {'team:team_a'}), isTrue);
    for (final follow in [
      'player:player_a',
      'competition:comp_a',
      'match:match_a',
    ]) {
      expect(isFollowedTeamMatch(match, {follow}), isFalse, reason: follow);
    }
  });
}

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/entities/entity_screen.dart';
import 'package:go_router/go_router.dart';

Snapshot _payload(String playerName) => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-10-01T12:00:00Z',
  'competitions': [
    {'id': 'fb_comp', 'name': 'Liga de Prueba', 'country': 'Costa Rica'},
  ],
  'teams': [
    {'id': 'fb_team', 'name': 'Club Local', 'country': 'Costa Rica'},
  ],
  'players': [
    {'id': 'fb_player', 'name': playerName, 'teamId': 'fb_team'},
  ],
  'standings': <dynamic>[],
  'matches': <dynamic>[],
  'news': <dynamic>[],
  'transfers': <dynamic>[],
});

/// Each read answers the next server version of the profile.
class _Repository implements FootballRepository {
  final names = ['Versión Uno', 'Versión Dos', 'Versión Tres'];
  int loads = 0;

  @override
  Future<Snapshot> load() async => _payload(names[loads++]);

  @override
  Future<Snapshot> loadDate(DateTime date) async => _payload(names.first);

  @override
  Future<MatchDetail> loadMatchDetail(String id) async => MatchDetail.empty(id);
}

void main() {
  testWidgets('a re-opened profile paints its last answer at once and '
      'revalidates it once it is old enough', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() => db.customSelect('select 1').get());
    final repository = _Repository();
    var now = DateTime.utc(2026, 10, 1, 12);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('Inicio')),
        ),
        GoRoute(
          path: '/player/:id',
          builder: (_, state) =>
              EntityScreen(type: 'player', id: state.pathParameters['id']!),
        ),
      ],
    );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        repositoryProvider.overrideWithValue(repository),
        clockProvider.overrideWithValue(() => now),
        followsProvider.overrideWith((ref) => Stream.value({})),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      router.dispose();
      container.dispose();
      await tester.runAsync(db.close);
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    Future<void> open() async {
      router.push('/player/fb_player');
      await tester.pump();
    }

    Future<void> close() async {
      router.pop();
      await tester.pumpAndSettle();
    }

    await open();
    await tester.pumpAndSettle();
    expect(find.text('Versión Uno'), findsWidgets);
    expect(repository.loads, 1);

    // Re-opened right away: the same answer, no new read.
    await close();
    await open();
    expect(find.text('Versión Uno'), findsWidgets);
    await tester.pumpAndSettle();
    expect(repository.loads, 1);

    // Re-opened later: first frame still shows the last answer (no
    // spinner), then the server's newer version replaces it.
    await close();
    now = now.add(entityRevalidateAfter);
    await open();
    expect(find.text('Versión Uno'), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpAndSettle();
    expect(repository.loads, 2);
    expect(find.text('Versión Dos'), findsWidgets);
    expect(find.text('Versión Uno'), findsNothing);
  });
}

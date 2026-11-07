import 'dart:async';

import 'package:dio/dio.dart';
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

class _PendingProfileRepository extends ApiRepository {
  _PendingProfileRepository(super.dio);

  final finish = Completer<void>();
  int attempts = 0;

  @override
  Stream<Snapshot> watchPublicEntity(String type, String id) async* {
    attempts++;
    if (attempts == 1) {
      yield _payload('Perfil guardado').asStale();
      await finish.future;
      return;
    }
    yield _payload('Perfil actualizado');
  }
}

void main() {
  testWidgets('reopening a cached profile reuses pending revalidation', (
    tester,
  ) async {
    final dio = Dio();
    final repository = _PendingProfileRepository(dio);
    final container = ProviderContainer(
      overrides: [repositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(dio.close);
    addTearDown(container.dispose);
    final request = (type: 'player', id: 'fb_player');
    bool? retried;
    Widget screen({required bool reopened}) => UncontrolledProviderScope(
      container: container,
      child: Consumer(
        builder: (_, ref, _) {
          if (reopened && retried == null) {
            retried = revalidateEntitySnapshot(ref, request);
          }
          final profile = ref.watch(entitySnapshotProvider(request));
          return Text(
            profile.value?.player('fb_player')?.name ?? '',
            textDirection: TextDirection.ltr,
          );
        },
      ),
    );
    await tester.pumpWidget(screen(reopened: false));
    await tester.pumpAndSettle();
    expect(find.text('Perfil guardado'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(screen(reopened: true));
    await tester.pumpAndSettle();
    expect(retried, isFalse);
    expect(repository.attempts, 1);
    expect(find.text('Perfil guardado'), findsOneWidget);

    repository.finish.complete();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    retried = null;
    await tester.pumpWidget(screen(reopened: true));
    await tester.pumpAndSettle();
    expect(retried, isTrue);
    expect(repository.attempts, 2);
    expect(find.text('Perfil actualizado'), findsOneWidget);
  });

  for (final initialError in [true, false]) {
    testWidgets('reopening retries a completed offline profile '
        '(${initialError ? 'cache miss' : 'stale cache'})', (tester) async {
      final request = (type: 'player', id: 'fb_player');
      var attempts = 0;
      final container = ProviderContainer(
        overrides: [
          entitySnapshotProvider(request).overrideWith((ref) async* {
            attempts++;
            if (attempts == 1) {
              if (initialError) throw StateError('offline');
              yield _payload('Perfil guardado').asStale();
            } else {
              yield _payload('Perfil actualizado');
            }
          }),
        ],
      );
      addTearDown(container.dispose);
      var reopen = false;
      var retried = false;
      Widget screen() => UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (_, ref, _) {
            if (reopen) {
              // Match the screen lifecycle: its re-entry check runs once.
              reopen = false;
              retried = revalidateEntitySnapshot(ref, request);
            }
            ref.watch(entitySnapshotProvider(request));
            return const SizedBox();
          },
        ),
      );
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      expect(attempts, 1);
      await tester.pumpWidget(const SizedBox());
      reopen = true;
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      expect(retried, isTrue);
      expect(attempts, 2);
      expect(
        container.read(entitySnapshotProvider(request)).requireValue.stale,
        isFalse,
      );
    });
  }

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

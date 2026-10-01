import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/profile_context.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/entities/entity_screen.dart';
import 'package:go_router/go_router.dart';

// Team profile first paint: a team the session already read (search,
// Explorar, calendar…) paints its header and independent sections at once,
// while the profile request is still in flight; sections that need it say
// they are loading. Synthetic fixtures only.

String _now() => DateTime.now().toUtc().toIso8601String();

Map<String, dynamic> _team(String id, String name) => {
  'id': id,
  'name': name,
  'country': 'Nowhere',
  'competitionId': 'fb_comp_seed',
};

const _competition = {
  'id': 'fb_comp_seed',
  'name': 'Liga Semilla',
  'country': 'Nowhere',
};

/// A `/v1/search` answer that mentions the team.
Map<String, dynamic> _search({Map<String, String> redirects = const {}}) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': _now(),
  'entityRedirects': redirects,
  'competitions': [_competition],
  'teams': [_team('fb_team_seed', 'Club Semilla')],
  'players': <dynamic>[],
  'matches': <dynamic>[],
  'standings': <dynamic>[],
};

/// The full `/v1/entity` profile, with its squad.
Snapshot _profile() => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': _now(),
  'coverage': {
    'squad': {'state': 'AVAILABLE'},
  },
  'competitions': [_competition],
  'teams': [_team('fb_team_seed', 'Club Semilla')],
  'players': [
    {
      'id': 'fb_player_seed',
      'name': 'Portero Semilla',
      'teamId': 'fb_team_seed',
      'position': 'Goalkeeper',
      'country': 'Nowhere',
    },
  ],
  'matches': <dynamic>[],
  'standings': <dynamic>[],
  'news': <dynamic>[],
  'transfers': <dynamic>[],
});

ApiRepository _repository(Map<String, dynamic> search) => ApiRepository(
  Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => options.path == '/v1/search'
            ? handler.resolve(Response(requestOptions: options, data: search))
            : handler.reject(DioException(requestOptions: options)),
      ),
    ),
);

class _Harness {
  _Harness(this.entity, this.contextRequests);
  final Completer<Snapshot> entity;
  final List<String> contextRequests;
}

Future<_Harness> _pump(WidgetTester tester, ApiRepository repository) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final db = AppDatabase(NativeDatabase.memory());
  final entity = Completer<Snapshot>();
  final contextRequests = <String>[];
  final router = GoRouter(
    initialLocation: '/team/fb_team_seed',
    routes: [
      GoRoute(
        path: '/team/:id',
        builder: (_, state) =>
            EntityScreen(type: 'team', id: state.pathParameters['id']!),
      ),
    ],
  );
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(repository),
      // The profile request is still in flight until the test completes it.
      entitySnapshotProvider.overrideWith((ref, request) => entity.future),
      // Never answers here: only records that it was asked (in parallel).
      teamContextProvider.overrideWith((ref, request) {
        contextRequests.add(request.teamId);
        return Completer<TeamContext?>().future;
      }),
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
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return _Harness(entity, contextRequests);
}

Future<void> _openTab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byType(TabBar), matching: find.text(label)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('a team found by search paints at once, then fills in', (
    tester,
  ) async {
    final repository = _repository(_search());
    await tester.runAsync(() => repository.searchCatalog('semilla', null));
    final harness = await _pump(tester, repository);

    // First paint while /v1/entity is still loading: no full-screen spinner.
    expect(harness.entity.isCompleted, isFalse);
    expect(find.text('FutBeat'), findsNothing);
    expect(find.text('Club Semilla'), findsWidgets);
    expect(find.text('Liga Semilla'), findsWidgets);
    expect(find.text('Resumen'), findsOneWidget);
    expect(find.byKey(const ValueKey('team-profile-loading')), findsOneWidget);
    // Independent sections start right away, in parallel with the profile.
    expect(harness.contextRequests, ['fb_team_seed']);

    // Sections that need the profile say "loading", never "empty/pending".
    await _openTab(tester, 'Plantilla');
    expect(find.byKey(const ValueKey('squad-loading')), findsOneWidget);
    expect(find.byKey(const ValueKey('squad-pending')), findsNothing);
    await _openTab(tester, 'Noticias');
    expect(find.byKey(const ValueKey('news-loading')), findsOneWidget);
    expect(find.text('Sin noticias disponibles'), findsNothing);
    await _openTab(tester, 'Plantilla');

    // The profile arrives: the same screen fills in (the tab stays put).
    harness.entity.complete(_profile());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('squad-loading')), findsNothing);
    expect(find.text('Portero Semilla'), findsOneWidget);
    expect(find.byKey(const ValueKey('team-profile-loading')), findsNothing);
    expect(find.text('FutBeat'), findsNothing);
  });

  testWidgets('an unknown team keeps the spinner until its profile arrives', (
    tester,
  ) async {
    final harness = await _pump(tester, _repository(_search()));
    expect(find.text('FutBeat'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Club Semilla'), findsNothing);

    harness.entity.complete(_profile());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('FutBeat'), findsNothing);
    expect(find.text('Club Semilla'), findsWidgets);
    expect(find.byKey(const ValueKey('team-profile-loading')), findsNothing);
  });

  group('ApiRepository.entitySeed', () {
    test('is null before anything mentions the team, and for non-teams', () {
      final repository = _repository(_search());
      expect(repository.entitySeed('team', 'fb_team_seed'), isNull);
    });

    test('carries the team and its competition from earlier reads', () async {
      final repository = _repository(_search());
      await repository.searchCatalog('semilla', null);
      final seed = repository.entitySeed('team', 'fb_team_seed')!;
      expect(seed.team('fb_team_seed')?.name, 'Club Semilla');
      expect(seed.competition('fb_comp_seed')?.name, 'Liga Semilla');
      expect(seed.players, isEmpty);
      expect(seed.matches, isEmpty);
      expect(repository.entitySeed('player', 'fb_team_seed'), isNull);
      expect(repository.entitySeed('team', 'fb_team_unknown'), isNull);
    });

    test('follows a redirected id to the canonical team', () async {
      final repository = _repository(
        _search(redirects: {'fb_team_old': 'fb_team_seed'}),
      );
      await repository.searchCatalog('semilla', null);
      final seed = repository.entitySeed('team', 'fb_team_old')!;
      expect(seed.resolveEntityId('fb_team_old'), 'fb_team_seed');
      expect(
        seed.team(seed.resolveEntityId('fb_team_old'))?.name,
        'Club Semilla',
      );
    });
  });
}

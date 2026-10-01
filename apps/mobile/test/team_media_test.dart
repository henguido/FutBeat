import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/entity_media.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/entities/entity_screen.dart';
import 'package:futbeat/shared/widgets.dart';
import 'package:go_router/go_router.dart';

// QA: a team crest hydrated lazily during the first visit reached the player
// profile but not the team header, the search row or Favoritos (initials
// "DS"). One resolver (EntityAvatar -> entityImageOf) and one session memory
// fed by every snapshot read. Synthetic ids and URLs only.

const _crest = 'https://media.example.test/fb_team_crest.png';

Map<String, dynamic> _team({bool crest = false, String id = 'fb_team'}) => {
  'id': id,
  'name': 'Deportivo Sintético',
  'country': 'Nowhere',
  if (crest) 'media': {'url': _crest, 'verificationStatus': 'VERIFIED'},
};

Map<String, dynamic> _payload({
  bool crest = false,
  Map<String, String> redirects = const {},
  String squad = 'AVAILABLE',
}) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-09-30T12:00:00Z',
  'coverage': {
    'squad': {'state': squad},
  },
  'entityRedirects': redirects,
  'competitions': <dynamic>[],
  'teams': [_team(crest: crest)],
  'players': <dynamic>[],
  'matches': <dynamic>[],
  'standings': <dynamic>[],
};

bool _showsCrest(WidgetTester tester, Finder within) => tester
    .widgetList<Image>(
      find.descendant(of: within, matching: find.byType(Image)),
    )
    .any((image) => (image.image as NetworkImage).url == _crest);

void main() {
  test('memory keeps verified media only, shares it with aliases and '
      'notifies only on change', () {
    final memory = EntityMediaMemory();
    var notified = 0;
    memory.addListener(() => notified++);
    memory.absorb(
      Snapshot({
        ..._payload(),
        'teams': [
          _team(),
          {
            ..._team(id: 'fb_team_unverified'),
            'media': {'url': _crest, 'verificationStatus': 'PENDING'},
          },
        ],
      }),
    );
    expect(memory.images, isEmpty);
    expect(notified, 0);
    memory.absorb(
      Snapshot(_payload(crest: true, redirects: {'fb_team_old': 'fb_team'})),
    );
    expect(memory.imageFor('fb_team'), _crest);
    expect(memory.imageFor('fb_team_old'), _crest);
    expect(notified, 1);
    // The same answer again (a refresh) changes nothing.
    memory.absorb(Snapshot(_payload(crest: true)));
    expect(notified, 1);
  });

  testWidgets('a crest learned later reaches every avatar of that team', (
    tester,
  ) async {
    final memory = EntityMediaMemory();
    // The search row / favorites row / header built from an older payload.
    final stale = Entity(_team());
    await tester.pumpWidget(
      MaterialApp(
        home: EntityMediaScope(
          memory: memory,
          child: Scaffold(
            body: Column(
              children: [
                EntityAvatar(stale, size: 64, key: const ValueKey('header')),
                EntityTile(stale, 'team', key: const ValueKey('row')),
                EntityAvatar(
                  Entity(_team(id: 'fb_other')),
                  key: const ValueKey('other'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.text('DS'), findsNWidgets(3));
    // Another screen (e.g. the player profile) reads the hydrated team.
    memory.absorb(Snapshot(_payload(crest: true)));
    await tester.pump();
    expect(_showsCrest(tester, find.byKey(const ValueKey('header'))), isTrue);
    expect(_showsCrest(tester, find.byKey(const ValueKey('row'))), isTrue);
    expect(_showsCrest(tester, find.byKey(const ValueKey('other'))), isFalse);
  });

  test('every snapshot the API repository reads feeds the memory', () async {
    final memory = EntityMediaMemory();
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response(
              requestOptions: options,
              data: _payload(crest: options.path == '/v1/entity'),
            ),
          ),
        ),
      );
    final repository = ApiRepository(
      dio,
      null,
      const CalendarCachePolicy(),
      memory,
    );
    await repository.searchCatalog('deportivo', null);
    expect(memory.imageFor('fb_team'), isNull);
    await repository.loadEntity('player', 'fb_player');
    expect(memory.imageFor('fb_team'), _crest);
  });

  testWidgets('team profile without a crest re-reads and picks it up', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await db.customSelect('select 1').get();
    });
    var reads = 0;
    final router = GoRouter(
      initialLocation: '/team/fb_team',
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
        // The server hydrates the crest while the profile is open.
        entitySnapshotProvider.overrideWith(
          (ref, request) async => Snapshot(_payload(crest: reads++ > 0)),
        ),
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
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(_showsCrest(tester, find.byType(EntityScreen)), isFalse);
    await tester.pump(profileEnrichmentRetryDelays.first);
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(_showsCrest(tester, find.byType(EntityScreen)), isTrue);
    // Crest and squad present: no further re-reads.
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(reads, 2);
  });
}

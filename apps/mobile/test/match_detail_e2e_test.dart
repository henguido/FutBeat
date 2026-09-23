import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/match_screen.dart';

// Mobile half of backend/test/match_detail_e2e.test.mjs: the fixture is the
// exact /v1/match-detail output that the backend test produces from a stored
// object-shaped GOAL lineup (canonical photos, fallbacks, statistics).

Map<String, dynamic> _fixture() => jsonDecode(
  File('test/fixtures/match_detail_object_lineup.json').readAsStringSync(),
);

Map<String, dynamic> _context() => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-09-01T21:00:00Z',
  'competitions': [
    {'id': 'fb_comp_e2e', 'name': 'Liga E2E'},
  ],
  'teams': [
    {'id': 'fb_team_e2e_home', 'name': 'Local E2E'},
    {'id': 'fb_team_e2e_away', 'name': 'Visita E2E'},
  ],
  'players': <dynamic>[],
  'standings': <dynamic>[],
  'matches': [
    {
      'id': 'fb_match_e2e',
      'competitionId': 'fb_comp_e2e',
      'homeTeamId': 'fb_team_e2e_home',
      'awayTeamId': 'fb_team_e2e_away',
      'startTime': '2026-09-01T18:00:00Z',
      'status': 'VERIFIED',
      'score': {'home': 1, 'away': 0},
      'events': <dynamic>[],
      'statistics': <dynamic>[],
    },
  ],
};

class _Api {
  _Api(this.detail);
  final Map<String, dynamic> detail;
  final requests = <String>[];

  Dio dio() => Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add('${options.path}?${options.queryParameters['request']}');
          final data = switch (options.path) {
            '/v1/match-context' => _context(),
            '/v1/match-detail' => detail,
            _ => null,
          };
          if (data == null) {
            handler.reject(DioException(requestOptions: options));
          } else {
            handler.resolve(Response(requestOptions: options, data: data));
          }
        },
      ),
    );
}

Future<ProviderContainer> _container(WidgetTester tester, _Api api) async {
  tester.view.physicalSize = const Size(360, 780);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final db = AppDatabase(NativeDatabase.memory());
  await tester.runAsync(() => db.customSelect('select 1').get());
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(ApiRepository(api.dio())),
      followsProvider.overrideWith((ref) => Stream.value({})),
      liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
    ],
  );
  addTearDown(() => tester.runAsync(db.close));
  return container;
}

/// Disposes inside the test body: retention timers must not outlive it.
Future<void> _close(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(const SizedBox());
  container.dispose();
}

Future<void> _open(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: MatchScreen(id: 'fb_match_e2e')),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tab(WidgetTester tester, String label) async {
  final tab = find.descendant(
    of: find.byType(TabBar),
    matching: find.text(label),
  );
  await tester.ensureVisible(tab);
  await tester.pumpAndSettle();
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

List<String> _networkImages(WidgetTester tester) => [
  for (final image in tester.widgetList<Image>(find.byType(Image)))
    if (image.image case ResizeImage(imageProvider: NetworkImage(:final url)))
      url
    else if (image.image case NetworkImage(:final url))
      url,
];

void main() {
  testWidgets(
    'stored object lineup renders with canonical photos and fallback',
    (tester) async {
      final api = _Api(_fixture());
      final container = await _container(tester, api);
      await _open(tester, container);
      await _tab(tester, 'Alineación');

      expect(find.text('Sin alineaciones'), findsNothing);
      // Starters sit on the pitch (initials + surname); bench shows full name.
      for (final label in ['PC', 'DS', 'DV', 'Suplente Canonico', 'DT Local']) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      expect(find.text('4-4-2'), findsOneWidget);
      final images = _networkImages(tester);
      expect(images, contains('https://media.goal-api.com/players/h1.png'));
      expect(images, contains('https://media.goal-api.com/players/a1.png'));
      // The player without any photo shows initials, never a broken image.
      expect(find.text('DS'), findsWidgets);
      expect(images.where((url) => url.isEmpty), isEmpty);
      expect(tester.takeException(), isNull);
      await _close(tester, container);
    },
  );

  testWidgets('stored statistics render translated with real values only', (
    tester,
  ) async {
    final api = _Api(_fixture());
    final container = await _container(tester, api);
    await _open(tester, container);
    await _tab(tester, 'Estadísticas');

    expect(find.text('Sin estadísticas'), findsNothing);
    expect(find.text('Posesión'), findsWidgets);
    expect(find.text('Tiros a puerta'), findsWidgets);
    expect(find.text('55%'), findsWidgets);
    expect(find.text('6'), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await _close(tester, container);
  });

  testWidgets('no stored detail ends in empty states, never a spinner', (
    tester,
  ) async {
    final api = _Api({
      'matchId': 'fb_match_e2e',
      'available': false,
      'pending': false,
      'detailLevel': 'none',
      'home': <String, dynamic>{},
      'away': <String, dynamic>{},
      'statistics': <dynamic>[],
      'incidents': <dynamic>[],
      'videos': <dynamic>[],
    });
    final container = await _container(tester, api);
    await _open(tester, container);
    await _tab(tester, 'Alineación');
    expect(find.text('Sin alineaciones'), findsOneWidget);
    await _tab(tester, 'Estadísticas');
    expect(find.text('Sin estadísticas'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('0'), findsNothing);
    await _close(tester, container);
  });

  testWidgets('leaving and re-entering a match does not refetch settled data', (
    tester,
  ) async {
    final api = _Api(_fixture());
    final container = await _container(tester, api);
    await _open(tester, container);
    final first = [...api.requests];
    expect(first.where((r) => r.startsWith('/v1/match-context')), hasLength(1));
    expect(first.where((r) => r.startsWith('/v1/match-detail')), hasLength(1));

    // Leave the Match Center and come back inside the retention window.
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump(const Duration(seconds: 20));
    await _open(tester, container);
    expect(api.requests, first);
    expect(find.text('Local E2E'), findsWidgets);

    // After the window, the next visit reads fresh data again (read-only).
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump(matchCacheRetention + const Duration(seconds: 1));
    await _open(tester, container);
    expect(api.requests.length, greaterThan(first.length));
    expect(
      api.requests
          .skip(first.length)
          .where(
            (r) => r.startsWith('/v1/match-detail') && r.endsWith('?null'),
          ),
      isEmpty,
      reason: 'repeat visits never re-request provider enrichment',
    );
    await _close(tester, container);
  });
}

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/entities/entity_screen.dart';
import 'package:futbeat/features/explore/explore_screen.dart';

// Mobile side of on-demand enrichment: partial data immediately, bounded
// automatic retries, never an infinite spinner.

Map<String, dynamic> _snapshot({
  List<Map<String, dynamic>> players = const [],
  List<Map<String, dynamic>> teams = const [],
  Map<String, dynamic> coverage = const {'partial': false},
}) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-09-23T12:00:00Z',
  'coverage': coverage,
  'competitions': <dynamic>[],
  'teams': teams,
  'players': players,
  'matches': <dynamic>[],
  'standings': <dynamic>[],
};

const _pending = {'partial': false, 'pendingRemote': true};

Future<List<RequestOptions>> _pumpExplore(
  WidgetTester tester,
  Map<String, dynamic> Function(int searchIndex) search,
) async {
  final requests = <RequestOptions>[];
  var searches = 0;
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          final data = options.path == '/v1/search'
              ? search(searches++)
              : _snapshot();
          handler.resolve(Response(requestOptions: options, data: data));
        },
      ),
    );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        repositoryProvider.overrideWithValue(ApiRepository(dio)),
        followsProvider.overrideWith((ref) => Stream.value({})),
      ],
      child: const MaterialApp(home: ExploreScreen()),
    ),
  );
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), 'julian alvarez');
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 10));
  return requests;
}

int _searches(List<RequestOptions> requests) =>
    requests.where((r) => r.path == '/v1/search').length;

void main() {
  testWidgets(
    'search shows local results at once, then re-queries while discovery runs',
    (tester) async {
      final requests = await _pumpExplore(
        tester,
        (i) => i < 2
            ? _snapshot(coverage: _pending)
            : _snapshot(
                players: [
                  {'id': 'fb_player_ja', 'name': 'Julián Álvarez'},
                ],
              ),
      );
      expect(_searches(requests), 1);
      expect(find.text('Buscando más jugadores…'), findsOneWidget);
      expect(find.text('No encontramos resultados'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(_searches(requests), 2);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(_searches(requests), 3);
      expect(find.text('Julián Álvarez'), findsOneWidget);
      expect(find.text('Buscando más jugadores…'), findsNothing);
      // Discovery finished: no further automatic requests.
      await tester.pump(const Duration(seconds: 30));
      expect(_searches(requests), 3);
    },
  );

  testWidgets(
    'pending discovery that never lands stops after bounded retries',
    (tester) async {
      final requests = await _pumpExplore(
        tester,
        (_) => _snapshot(coverage: _pending),
      );
      for (final delay in remoteSearchRetryDelays) {
        await tester.pump(delay);
        await tester.pump();
      }
      expect(_searches(requests), 1 + remoteSearchRetryDelays.length);
      expect(find.text('Buscando más jugadores…'), findsNothing);
      expect(find.text('No encontramos resultados'), findsOneWidget);
      expect(
        find.text('Seguimos buscando; intenta de nuevo en unos segundos.'),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pump(const Duration(minutes: 1));
      expect(_searches(requests), 1 + remoteSearchRetryDelays.length);
    },
  );

  testWidgets('a pending search is never served from the client cache', (
    tester,
  ) async {
    final requests = await _pumpExplore(
      tester,
      (i) => _snapshot(coverage: i == 0 ? _pending : const {'partial': false}),
    );
    await tester.pump(remoteSearchRetryDelays.first);
    await tester.pump();
    expect(_searches(requests), 2);
  });

  Future<List<int>> pumpPlayer(
    WidgetTester tester,
    Map<String, dynamic> Function(int load) payload,
  ) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() => db.customSelect('select 1').get());
    final loads = <int>[];
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        entitySnapshotProvider.overrideWith((ref, request) async {
          loads.add(loads.length);
          return Snapshot(payload(loads.length - 1));
        }),
        followsProvider.overrideWith((ref) => Stream.value({})),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await tester.runAsync(db.close);
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: EntityScreen(type: 'player', id: 'fb_player_x'),
        ),
      ),
    );
    // Explicit pumps: the enrichment spinner animates, so pumpAndSettle would
    // fast-forward past the refresh timers.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return loads;
  }

  Map<String, dynamic> player({bool pending = false, int? height}) => {
    ..._snapshot(
      coverage: {
        'partial': false,
        'enrichmentPending': ?(pending ? true : null),
      },
      players: [
        {
          'id': 'fb_player_x',
          'name': 'Jugador Parcial',
          'country': 'Costa Rica',
          'height': ?height,
        },
      ],
    ),
  };

  testWidgets('player: partial profile now, refreshed once enrichment lands', (
    tester,
  ) async {
    final loads = await pumpPlayer(
      tester,
      (i) => i == 0 ? player(pending: true) : player(height: 182),
    );
    expect(find.text('Jugador Parcial'), findsWidgets);
    expect(find.text('Costa Rica'), findsWidgets);
    expect(find.byKey(const ValueKey('player-enriching')), findsOneWidget);
    await tester.pump(profileEnrichmentRetryDelays.first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(loads.length, 2);
    expect(find.text('182 cm'), findsOneWidget);
    expect(find.byKey(const ValueKey('player-enriching')), findsNothing);
    await tester.pump(const Duration(minutes: 1));
    expect(loads.length, 2);
  });

  testWidgets(
    'player: enrichment that never lands stops after bounded refreshes',
    (tester) async {
      final loads = await pumpPlayer(tester, (_) => player(pending: true));
      for (final delay in profileEnrichmentRetryDelays) {
        await tester.pump(delay);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(loads.length, 1 + profileEnrichmentRetryDelays.length);
      expect(find.byKey(const ValueKey('player-enriching')), findsNothing);
      await tester.pump(const Duration(minutes: 1));
      expect(loads.length, 1 + profileEnrichmentRetryDelays.length);
    },
  );
}

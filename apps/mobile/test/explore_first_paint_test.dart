import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/explore/explore_screen.dart';

// Explorar first paint (field report: an empty page with only a thin
// progress bar for 10-20 s on the first open of a session). Suggestions now
// paint from the last stored answer at once, global and country requests run
// in parallel and neither waits for the other.

Map<String, dynamic> _catalog(String competition, String team) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-10-02T12:00:00Z',
  'coverage': {'partial': false},
  'freshness': {'stale': false},
  'competitions': [
    {'id': 'c_$competition', 'name': competition},
  ],
  'teams': [
    {'id': 't_$team', 'name': team},
  ],
  'players': const <dynamic>[],
  'matches': const <dynamic>[],
  'standings': const <dynamic>[],
  'news': const <dynamic>[],
  'transfers': const <dynamic>[],
};

/// Holds every `/v1/explore` request until the test answers it.
class _ExploreServer {
  _ExploreServer(this.dio) {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final country = options.queryParameters['country'] as String?;
          requests.add(country);
          pending[country] = (options, handler);
        },
      ),
    );
  }

  final Dio dio;
  final List<String?> requests = [];
  final Map<String?, (RequestOptions, RequestInterceptorHandler)> pending = {};

  void answer(String? country, Map<String, dynamic> data) {
    final (options, handler) = pending.remove(country)!;
    handler.resolve(Response(requestOptions: options, data: data));
  }

  void fail(String? country) {
    final (options, handler) = pending.remove(country)!;
    handler.reject(
      DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
      ),
    );
  }
}

/// Lets the in-memory drift reads and the held Dio requests progress inside
/// a widget test (no response is produced: the server holds them).
Future<void> _settleIo(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 1));
  }
}

Future<void> _flush() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('ApiRepository.watchExplore', () {
    test(
      'global starts before the country is known; both run in parallel and '
      'a quicker global answer is an interim, the country answer final',
      () async {
        final server = _ExploreServer(Dio());
        final repository = ApiRepository(server.dio);
        final country = Completer<String?>();
        final values = <Snapshot>[];
        final done = Completer<void>();
        repository
            .watchExplore(country.future)
            .listen(values.add, onDone: done.complete);
        await _flush();
        // Global is already in flight while the preference is unknown.
        expect(server.requests, [null]);
        country.complete('cr');
        await _flush();
        expect(server.requests, [null, 'CR']);
        expect(server.pending.keys, containsAll([null, 'CR']));
        server.answer(null, _catalog('Global League', 'Global Club'));
        await _flush();
        expect(values.single.competitions.single.name, 'Global League');
        expect(values.single.revalidating, true);
        server.answer('CR', _catalog('Local League', 'Local Club'));
        await done.future;
        expect(values.last.competitions.single.name, 'Local League');
        expect(values.last.revalidating, false);
        expect(values.length, 2);
        server.dio.close(force: true);
      },
    );

    test(
      'a quicker country answer is final; the later global is ignored',
      () async {
        final server = _ExploreServer(Dio());
        final repository = ApiRepository(server.dio);
        final values = <Snapshot>[];
        final done = Completer<void>();
        repository
            .watchExplore(Future.value('CR'))
            .listen(values.add, onDone: done.complete);
        await _flush();
        expect(server.requests, [null, 'CR']);
        server.answer('CR', _catalog('Local League', 'Local Club'));
        await _flush();
        expect(values.single.competitions.single.name, 'Local League');
        server.answer(null, _catalog('Global League', 'Global Club'));
        await done.future;
        expect(values.length, 1);
        server.dio.close(force: true);
      },
    );

    test('a failed country request falls back to the global answer', () async {
      final server = _ExploreServer(Dio());
      final repository = ApiRepository(server.dio);
      final values = <Snapshot>[];
      final done = Completer<void>();
      repository
          .watchExplore(Future.value('CR'))
          .listen(values.add, onDone: done.complete);
      await _flush();
      server.fail('CR');
      await _flush();
      server.answer(null, _catalog('Global League', 'Global Club'));
      await done.future;
      expect(values.last.competitions.single.name, 'Global League');
      expect(values.last.stale, false);
      server.dio.close(force: true);
    });

    test(
      'a preference that fails or times out still serves the global list',
      () async {
        final server = _ExploreServer(Dio());
        final repository = ApiRepository(server.dio);
        final values = <Snapshot>[];
        final done = Completer<void>();
        final preference = Completer<String?>();
        repository
            .watchExplore(preference.future)
            .listen(values.add, onDone: done.complete);
        await _flush();
        preference.completeError(TimeoutException('pref'));
        await _flush();
        expect(server.requests, [null]);
        server.answer(null, _catalog('Global League', 'Global Club'));
        await done.future;
        expect(values.single.competitions.single.name, 'Global League');
        server.dio.close(force: true);
      },
    );

    test(
      'answers are stored on the device; the next session paints them at '
      'once (revalidating) and keeps them, marked stale, when offline',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final first = _ExploreServer(Dio());
        final firstRepository = ApiRepository(first.dio, db);
        final loading = firstRepository.loadExplore(country: 'CR');
        await _flush();
        first.answer('CR', _catalog('Local League', 'Local Club'));
        await loading;
        await firstRepository.settleBackground();
        first.dio.close(force: true);

        // A new session: empty memory, same device database.
        final second = _ExploreServer(Dio());
        final repository = ApiRepository(second.dio, db);
        final values = <Snapshot>[];
        final done = Completer<void>();
        repository
            .watchExplore(Future.value('CR'))
            .listen(values.add, onDone: done.complete);
        await _flush();
        expect(values.single.competitions.single.name, 'Local League');
        expect(values.single.revalidating, true);
        // A quicker global answer never replaces the stored country list.
        second.answer(null, _catalog('Global League', 'Global Club'));
        await _flush();
        expect(values.length, 1);
        second.fail('CR');
        await done.future;
        expect(values.last.competitions.single.name, 'Local League');
        expect(values.last.stale, true);
        second.dio.close(force: true);
      },
    );

    test(
      'a different country paints the stored global list meanwhile',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        await db.saveCatalogSnapshot(
          'explore',
          '{"schemaVersion":1,"demo":false,"updatedAt":"2026-10-02T12:00:00Z",'
              '"competitions":[{"id":"c_g","name":"Stored Global"}],"teams":[],'
              '"players":[],"matches":[],"standings":[],"news":[],"transfers":[]}',
        );
        final server = _ExploreServer(Dio());
        final repository = ApiRepository(server.dio, db);
        final values = <Snapshot>[];
        repository.watchExplore(Future.value('ES')).listen(values.add);
        await _flush();
        expect(values.single.competitions.single.name, 'Stored Global');
        expect(values.single.revalidating, true);
        server.dio.close(force: true);
      },
    );

    test(
      'nothing stored and both requests failing ends in the error',
      () async {
        final server = _ExploreServer(Dio());
        final repository = ApiRepository(server.dio);
        final values = <Snapshot>[];
        final error = Completer<Object>();
        repository
            .watchExplore(Future.value('CR'))
            .listen(values.add, onError: (Object e) => error.complete(e));
        await _flush();
        server.fail(null);
        server.fail('CR');
        expect(await error.future, isA<DioException>());
        expect(values, isEmpty);
        server.dio.close(force: true);
      },
    );

    test('device copies are bounded', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      for (var i = 0; i < maxCatalogSnapshots + 3; i++) {
        await db.saveCatalogSnapshot('explore:K$i', '{}');
      }
      final rows = await db.select(db.catalogSnapshots).get();
      expect(rows.length, maxCatalogSnapshots);
    });
  });

  testWidgets(
    'Explorar paints the stored suggestions on the first frame, then refreshes',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final server = _ExploreServer(Dio());
      await tester.runAsync(() async {
        await db.saveCatalogSnapshot(
          'explore:CR',
          '{"schemaVersion":1,"demo":false,"updatedAt":"2026-10-02T12:00:00Z",'
              '"competitions":[{"id":"c_old","name":"Stored League"}],'
              '"teams":[{"id":"t_old","name":"Stored Club"}],'
              '"players":[],"matches":[],"standings":[],"news":[],'
              '"transfers":[]}',
        );
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            repositoryProvider.overrideWithValue(ApiRepository(server.dio, db)),
            followsProvider.overrideWith((ref) => Stream.value({})),
            preferenceProvider.overrideWith(
              (ref) => Stream.value(
                const CountryPreference(
                  detectedCountry: 'CR',
                  selectedCountry: null,
                  bootstrapDismissed: true,
                ),
              ),
            ),
          ],
          child: const MaterialApp(home: ExploreScreen()),
        ),
      );
      await _settleIo(tester);
      // Content before any response, with the thin refresh bar.
      expect(server.requests, [null, 'CR']);
      expect(find.text('Competiciones destacadas'), findsOneWidget);
      expect(find.text('Stored League'), findsOneWidget);
      expect(find.text('Stored Club'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      server.answer('CR', _catalog('Fresh League', 'Fresh Club'));
      server.answer(null, _catalog('Global League', 'Global Club'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Fresh League'), findsOneWidget);
      expect(find.text('Stored League'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      server.dio.close(force: true);
      await tester.runAsync(db.close);
    },
  );

  testWidgets('a failed refresh keeps the stored suggestions and offers Retry', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final server = _ExploreServer(Dio());
    await tester.runAsync(() async {
      await db.saveCatalogSnapshot(
        'explore',
        '{"schemaVersion":1,"demo":false,"updatedAt":"2026-10-02T12:00:00Z",'
            '"competitions":[{"id":"c_old","name":"Stored League"}],"teams":[],'
            '"players":[],"matches":[],"standings":[],"news":[],"transfers":[]}',
      );
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repositoryProvider.overrideWithValue(ApiRepository(server.dio, db)),
          followsProvider.overrideWith((ref) => Stream.value({})),
          preferenceProvider.overrideWith(
            (ref) => Stream.value(
              const CountryPreference(
                detectedCountry: null,
                selectedCountry: null,
                bootstrapDismissed: true,
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: ExploreScreen()),
      ),
    );
    await _settleIo(tester);
    expect(find.text('Stored League'), findsOneWidget);
    server.fail(null);
    await tester.pump();
    await tester.pump();
    expect(find.text('Stored League'), findsOneWidget);
    expect(
      find.text(
        'No pudimos actualizar. Conservamos los resultados disponibles.',
      ),
      findsOneWidget,
    );
    expect(find.text('Reintentar'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    server.dio.close(force: true);
    await tester.runAsync(db.close);
  });
}

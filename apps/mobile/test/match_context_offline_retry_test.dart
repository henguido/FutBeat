import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/match_screen.dart';

Snapshot _match() => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-10-30T00:00:00Z',
  'competitions': [
    {'id': 'fb_comp_offline', 'name': 'Serie A'},
  ],
  'teams': [
    {'id': 'fb_team_home', 'name': 'Fiorentina'},
    {'id': 'fb_team_away', 'name': 'Atalanta'},
  ],
  'players': <dynamic>[],
  'standings': <dynamic>[],
  'matches': [
    {
      'id': 'fb_match_offline',
      'competitionId': 'fb_comp_offline',
      'homeTeamId': 'fb_team_home',
      'awayTeamId': 'fb_team_away',
      'startTime': '2026-10-29T18:00:00Z',
      'status': 'VERIFIED',
      'score': {'home': 2, 'away': 2},
      'events': <dynamic>[],
      'statistics': <dynamic>[],
    },
  ],
});

void main() {
  test('leaving Match Center cancels an in-flight context read', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.customSelect('select 1').get();
    final started = Completer<void>();
    final release = Completer<void>();
    CancelToken? requestToken;
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            requestToken = options.cancelToken;
            started.complete();
            await release.future;
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
              ),
            );
          },
        ),
      );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        repositoryProvider.overrideWithValue(ApiRepository(dio, db)),
      ],
    );
    final subscription = container.listen(
      matchContextSnapshotProvider('fb_match_offline'),
      (_, _) {},
    );
    await started.future.timeout(const Duration(seconds: 2));
    subscription.close();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final cancelled = requestToken?.isCancelled == true;
    release.complete();
    container.dispose();
    dio.close(force: true);
    await db.close();
    expect(cancelled, isTrue);
  });

  testWidgets('offline tabs do not restart a failed match-context read', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() => db.customSelect('select 1').get());
    addTearDown(() => tester.runAsync(db.close));
    var contextAttempts = 0;
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/v1/match-context') contextAttempts++;
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
              ),
            );
          },
        ),
      );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        repositoryProvider.overrideWithValue(ApiRepository(dio, db)),
        followsProvider.overrideWith((ref) => Stream.value({})),
        liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: MatchScreen(id: 'fb_match_offline', initialData: _match()),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    for (final label in ['Alineación', 'Estadísticas', 'Tabla']) {
      final tab = find.descendant(
        of: find.byType(TabBar),
        matching: find.text(label),
      );
      await tester.ensureVisible(tab);
      await tester.tap(tab);
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pump(const Duration(seconds: 12));
    expect(contextAttempts, 2);
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  });
}

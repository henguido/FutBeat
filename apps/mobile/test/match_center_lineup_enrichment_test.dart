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

Map<String, dynamic> _detail({required bool pending}) => {
  'matchId': 'fb_match',
  'available': true,
  'pending': false,
  'detailLevel': 'full',
  'home': <String, dynamic>{},
  'away': <String, dynamic>{},
  'statistics': const [],
  'incidents': const [],
  'coverage': {'lineupEnrichmentPending': pending},
};

void main() {
  testWidgets(
    'lineupEnrichmentPending schedules a bounded refresh, then stops (no infinite spinner)',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase(NativeDatabase.memory());
      final payload = _payload();
      // Broadcast: ref.invalidate() re-subscribes matchDetailProvider each
      // retry, which a single-subscription StreamController would reject.
      final detailController = StreamController<MatchDetail>.broadcast();
      addTearDown(detailController.close);
      // Counts real re-subscriptions caused by ref.invalidate(matchDetailProvider),
      // so this test fails if _scheduleLineupEnrichmentRefresh became a no-op
      // (a bounded-timer-count assertion alone would not catch that).
      var subscriptionCount = 0;

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          repositoryProvider.overrideWithValue(ApiRepository(Dio())),
          matchContextSnapshotProvider.overrideWith(
            (ref, id) async => Snapshot(payload),
          ),
          matchDetailProvider.overrideWith((ref, id) {
            subscriptionCount++;
            return detailController.stream;
          }),
          followsProvider.overrideWith((ref) => Stream.value({})),
          liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
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
          child: MaterialApp(
            home: MatchScreen(id: 'fb_match', initialData: Snapshot(payload)),
          ),
        ),
      );
      detailController.add(MatchDetail(_detail(pending: true)));
      await tester.pump();
      await tester.pump();

      // Two bounded retries (6s, 12s) then no more, per _lineupEnrichmentRetryDelays.
      await tester.pump(const Duration(seconds: 6));
      detailController.add(MatchDetail(_detail(pending: true)));
      await tester.pump();
      await tester.pump(const Duration(seconds: 12));
      detailController.add(MatchDetail(_detail(pending: true)));
      await tester.pump();

      // No third timer is scheduled: advancing further does not throw, and
      // flutter_test itself fails this test if any Timer is still pending
      // when it ends, so an unbounded retry loop would fail here.
      await tester.pump(const Duration(seconds: 30));
      expect(tester.takeException(), isNull);

      // The provider was genuinely re-subscribed twice (the 6s and 12s
      // retries), on top of the initial subscription -- proving the refresh
      // actually re-fetches instead of just scheduling timers that do nothing.
      expect(subscriptionCount, 3);
    },
  );
}

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

import 'r3_match_center_regressions_test.dart' show fixture;

Snapshot head(
  int minute,
  int goals, {
  String status = 'LIVE',
  String id = 'fb_match',
}) {
  final data = fixture(status);
  return Snapshot({
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': data.updatedAt.toIso8601String(),
    'teams': data.teams.map((e) => e.json).toList(),
    'competitions': data.competitions.map((e) => e.json).toList(),
    'players': [],
    'standings': [],
    'matches': [
      {
        ...data.matches.single.json,
        'id': id,
        'minute': minute,
        'score': {'home': goals, 'away': 0},
      },
    ],
  });
}

void main() {
  testWidgets(
    'D1v2 open center follows shared HTTP calendar without Realtime or another demand',
    (t) async {
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (o, h) => h.reject(DioException(requestOptions: o)),
          ),
        );
      final calendar = StreamController<Snapshot>();
      var context = head(4, 0);
      var reads = 0;
      final c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          repositoryProvider.overrideWithValue(ApiRepository(dio, db)),
          matchCalendarSyncEnabledProvider.overrideWithValue(true),
          calendarSnapshotProvider.overrideWith((ref, date) => calendar.stream),
          matchContextSnapshotProvider.overrideWith((ref, id) {
            reads++;
            return Stream.value(context);
          }),
          matchDetailProvider.overrideWith(
            (ref, id) => Stream.value(
              MatchDetail({
                'matchId': id,
                'available': true,
                'pending': false,
                'home': {},
                'away': {},
                'statistics': [],
              }),
            ),
          ),
          matchPreviewProvider.overrideWith(
            (ref, id) async => MatchPreview.empty(id),
          ),
          followsProvider.overrideWith((ref) => Stream.value({})),
          liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
        ],
      );
      addTearDown(() async {
        await t.pumpWidget(const SizedBox());
        c.dispose();
        await calendar.close();
        dio.close();
        await t.runAsync(db.close);
      });
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: MatchScreen(id: 'fb_match', initialData: context),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('0 - 0'), findsWidgets);
      // The calendar can arrive before the context read model/cache catches up.
      // An unchanged later calendar answer must still allow that context to recover.
      calendar.add(head(8, 1));
      await t.pumpAndSettle();
      expect(find.text('0 - 0'), findsWidgets);
      final laggingReads = reads;
      context = head(8, 1);
      calendar.add(head(8, 1));
      await t.pumpAndSettle();
      expect(reads, laggingReads + 1);
      expect(find.text('1 - 0'), findsWidgets);
      final initialReads = reads;
      await t.tap(find.byKey(const ValueKey('match-tab-lineup')));
      await t.pumpAndSettle();
      context = head(19, 1);
      calendar.add(context);
      await t.pumpAndSettle();
      expect(find.text('1 - 0'), findsWidgets);
      expect(reads, initialReads + 1);
      final bar = t.widget<TabBar>(find.byType(TabBar));
      expect((bar.tabs[bar.controller!.index] as Tab).text, 'Alineación');
      // New cache/observation objects with unchanged sports content do not poll context again.
      calendar.add(head(19, 1));
      await t.pumpAndSettle();
      expect(reads, initialReads + 1);
      calendar.add(head(20, 3, id: 'fb_unrelated_match'));
      await t.pumpAndSettle();
      expect(reads, initialReads + 1);
      calendar.add(head(20, 3).asStale());
      await t.pumpAndSettle();
      expect(reads, initialReads + 1);
      calendar.addError(StateError('offline fixture'));
      await t.pumpAndSettle();
      expect(find.text('1 - 0'), findsWidgets);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await t.pump();
      context = head(20, 2);
      calendar.add(context);
      await t.pumpAndSettle();
      expect(reads, initialReads + 1);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump();
      calendar.add(context);
      await t.pumpAndSettle();
      expect(find.text('2 - 0'), findsWidgets);
      expect(reads, initialReads + 2);
      context = head(20, 2, status: 'VERIFIED');
      calendar.add(context);
      await t.pumpAndSettle();
      expect(find.text('2 - 0'), findsWidgets);
      final terminalReads = reads;
      calendar.add(head(21, 0, status: 'SCHEDULED'));
      await t.pumpAndSettle();
      expect(reads, terminalReads);
      expect(find.text('2 - 0'), findsWidgets);
      expect(t.takeException(), isNull);
    },
  );
}

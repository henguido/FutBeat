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

import 'd1v2_match_calendar_sync_test.dart' show head;

void main() {
  for (final status in ['LIVE', 'VERIFIED']) {
    testWidgets('$status visible state survives an old cached context', (
      t,
    ) async {
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio();
      final answers = StreamController<Snapshot>();
      final initial = head(70, 2, status: status);
      final c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          repositoryProvider.overrideWithValue(ApiRepository(dio, db)),
          matchCalendarSyncEnabledProvider.overrideWithValue(false),
          matchContextSnapshotProvider.overrideWith(
            (ref, id) => answers.stream,
          ),
          matchDetailProvider.overrideWith(
            (ref, id) => Stream.value(MatchDetail.waiting(id)),
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
        await answers.close();
        dio.close();
        await t.runAsync(db.close);
      });
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: MatchScreen(id: 'fb_match', initialData: initial),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('2 - 0'), findsWidgets);
      answers.add(head(0, 0, status: 'SCHEDULED').asStale());
      await t.pumpAndSettle();
      expect(find.text('2 - 0'), findsWidgets);
      expect(
        find.byKey(const ValueKey('match-tab-live')),
        status == 'LIVE' ? findsOneWidget : findsNothing,
      );
      // A later network answer remains authoritative, including genuine corrections.
      answers.add(head(80, 3, status: 'VERIFIED'));
      await t.pumpAndSettle();
      expect(find.text('3 - 0'), findsWidgets);
      answers.add(head(1, 0).asStale());
      await t.pumpAndSettle();
      expect(find.text('3 - 0'), findsWidgets);
      // Cache protection must never freeze an official status correction.
      answers.add(head(0, 0, status: 'POSTPONED'));
      await t.pumpAndSettle();
      expect(find.text('APLAZADO'), findsOneWidget);
      expect(find.byKey(const ValueKey('match-tab-live')), findsNothing);
      answers.add(head(80, 3, status: 'VERIFIED').asStale());
      await t.pumpAndSettle();
      expect(find.text('APLAZADO'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}

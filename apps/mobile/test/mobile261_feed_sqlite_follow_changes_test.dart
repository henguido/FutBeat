import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/matches_screen.dart';

class _StoredCalendar implements FootballRepository {
  var loads = 0;
  final data = Snapshot({
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': '2026-11-03T18:00:00Z',
    'teams': [
      for (final id in ['a', 'b', 'c', 'd'])
        {'id': 'fb_team_$id', 'name': 'Team $id'},
    ],
    'competitions': [
      for (final id in ['one', 'two'])
        {'id': 'fb_comp_$id', 'name': 'League $id'},
    ],
    'players': [],
    'standings': [],
    'matches': [
      for (var i = 1; i <= 3; i++)
        {
          'id': 'fb_match_$i',
          'competitionId': i == 1 ? 'fb_comp_one' : 'fb_comp_two',
          'homeTeamId': i == 3 ? 'fb_team_d' : 'fb_team_a',
          'awayTeamId': i == 1 ? 'fb_team_b' : 'fb_team_c',
          'startTime': '2026-11-03T18:00:00Z',
          'status': 'VERIFIED',
          'score': {'home': i, 'away': 0},
        },
    ],
  });
  @override
  Future<Snapshot> load() async {
    loads++;
    return data;
  }

  @override
  Future<Snapshot> loadDate(DateTime date) async {
    loads++;
    return data;
  }

  @override
  Future<MatchDetail> loadMatchDetail(String id) async =>
      throw StateError('No detail traffic expected');
}

void main() {
  testWidgets(
    'SQLite follow changes update favorites and retain every league without reloading calendar',
    (tester) async {
      tester.view.physicalSize = const Size(420, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase(NativeDatabase.memory());
      final repo = _StoredCalendar();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          repositoryProvider.overrideWithValue(repo),
          preferenceProvider.overrideWith(
            (ref) => Stream.value(
              const CountryPreference(
                selectedCountry: null,
                detectedCountry: null,
                bootstrapDismissed: true,
              ),
            ),
          ),
          liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        container.dispose();
        await tester.runAsync(db.close);
      });
      Future<void> change(
        Future<void> Function() write,
        Set<String> expected,
      ) async {
        final arrived = Completer<void>();
        final observer = container.listen(followsProvider, (_, state) {
          final value = state.asData?.value;
          if (value != null &&
              value.length == expected.length &&
              value.containsAll(expected) &&
              !arrived.isCompleted) {
            arrived.complete();
          }
        }, fireImmediately: true);
        try {
          await tester.runAsync(write);
          await tester.runAsync(
            () => arrived.future.timeout(const Duration(seconds: 5)),
          );
          await tester.pumpAndSettle();
        } finally {
          observer.close();
        }
      }

      Finder row(String match, String scope, String competition) =>
          find.descendant(
            of: find.byKey(ValueKey('feed-section-$scope-$competition')),
            matching: find.byKey(ValueKey('match-row-$match')),
          );
      void assertLeagueRows() {
        expect(row('fb_match_1', 'competition', 'fb_comp_one'), findsOneWidget);
        expect(row('fb_match_2', 'competition', 'fb_comp_two'), findsOneWidget);
        expect(row('fb_match_3', 'competition', 'fb_comp_two'), findsOneWidget);
      }

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: MatchesScreen(now: () => DateTime(2026, 11, 3, 12)),
          ),
        ),
      );
      await tester.runAsync(() => container.read(followsProvider.future));
      await tester.pumpAndSettle();
      assertLeagueRows();
      expect(find.text('FAVORITOS'), findsNothing);
      await change(() => db.addFollows(['team:fb_team_a', 'team:fb_team_a']), {
        'team:fb_team_a',
      });
      expect(find.text('FAVORITOS'), findsOneWidget);
      expect(row('fb_match_1', 'favorite', 'fb_comp_one'), findsOneWidget);
      expect(row('fb_match_2', 'favorite', 'fb_comp_two'), findsOneWidget);
      expect(row('fb_match_3', 'favorite', 'fb_comp_two'), findsNothing);
      assertLeagueRows();
      await change(
        () => db.addFollows(['competition:fb_comp_two', 'player:fb_player_a']),
        {'team:fb_team_a', 'competition:fb_comp_two', 'player:fb_player_a'},
      );
      expect(row('fb_match_3', 'favorite', 'fb_comp_two'), findsNothing);
      assertLeagueRows();
      await change(() => db.removeFollows(['team:fb_team_a']), {
        'competition:fb_comp_two',
        'player:fb_player_a',
      });
      expect(find.text('FAVORITOS'), findsNothing);
      assertLeagueRows();
      expect(
        repo.loads,
        1,
        reason: 'follow changes repartition stored feed without a new calendar read',
      );
      expect(tester.takeException(), isNull);
    },
  );
}

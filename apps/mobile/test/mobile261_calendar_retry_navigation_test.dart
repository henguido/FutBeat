import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/matches_screen.dart';

Snapshot _day(DateTime day) => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-11-03T18:00:00Z',
  'teams': [
    {'id': 'fb_team_a', 'name': 'Team A'},
    {'id': 'fb_team_b', 'name': 'Team B'},
  ],
  'competitions': [
    {'id': 'fb_comp_a', 'name': 'Fixture league'},
  ],
  'players': [],
  'standings': [],
  'matches': [
    {
      'id': 'fb_match_day${day.day}',
      'competitionId': 'fb_comp_a',
      'homeTeamId': 'fb_team_a',
      'awayTeamId': 'fb_team_b',
      'startTime': DateTime.utc(
        day.year,
        day.month,
        day.day,
        18,
      ).toIso8601String(),
      'status': 'VERIFIED',
      'score': {'home': day.day, 'away': 0},
    },
  ],
});

class _LocalRepository implements FootballRepository {
  @override
  Future<Snapshot> load() async => _day(DateTime(2026, 11, 3));
  @override
  Future<Snapshot> loadDate(DateTime date) async => _day(date);
  @override
  Future<MatchDetail> loadMatchDetail(String id) async => MatchDetail.empty(id);
}

void main() {
  testWidgets(
    'pending retry of old day cannot block new day retry or replace its rows',
    (tester) async {
      final now = DateTime(2026, 11, 3, 12);
      final oldRetry = StreamController<Snapshot>();
      final oldCancelled = Completer<void>();
      oldRetry.onCancel = () {
        if (!oldCancelled.isCompleted) {
          oldCancelled.complete();
        }
      };
      final reads = <int, int>{};
      final container = ProviderContainer(
        overrides: [
          repositoryProvider.overrideWithValue(_LocalRepository()),
          calendarSnapshotProvider.overrideWith((ref, date) {
            final attempt = reads.update(
              date.day,
              (count) => count + 1,
              ifAbsent: () => 1,
            );
            if (attempt == 1) {
              return Stream.error(StateError('Synthetic calendar failure'));
            }
            if (date.day == 3) return oldRetry.stream;
            return Stream.value(_day(date));
          }),
          followsProvider.overrideWith((ref) => Stream.value(<String>{})),
          preferenceProvider.overrideWith(
            (ref) => Stream.value(
              const CountryPreference(
                detectedCountry: null,
                selectedCountry: null,
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
        await oldRetry.close();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: MatchesScreen(now: () => now)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reintentar'));
      await tester.pumpAndSettle();
      expect(reads[3], 2);
      final swipe = tester.widget<GestureDetector>(
        find.byKey(const ValueKey('matches-date-swipe')),
      );
      swipe.onHorizontalDragEnd!(
        DragEndDetails(
          primaryVelocity: -600,
          velocity: const Velocity(pixelsPerSecond: Offset(-600, 0)),
        ),
      );
      await tester.pumpAndSettle();
      expect(reads[4], 1);
      expect(
        oldCancelled.isCompleted,
        isTrue,
        reason: 'old date observer must be released',
      );
      expect(find.text('Reintentar'), findsOneWidget);
      expect(find.text('Reintentando…'), findsNothing);
      await tester.tap(find.text('Reintentar'));
      await tester.pumpAndSettle();
      expect(reads[4], 2);
      expect(
        find.byKey(const ValueKey('match-row-fb_match_day4')),
        findsOneWidget,
      );
      oldRetry.add(_day(DateTime(2026, 11, 3)));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('match-row-fb_match_day4')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('match-row-fb_match_day3')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

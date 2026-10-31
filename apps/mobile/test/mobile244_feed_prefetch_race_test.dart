import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/matches_screen.dart';

class _ObservedStoredRepository extends ApiRepository {
  _ObservedStoredRepository(super.dio);
  final reads = <String>[];
  @override
  Future<MatchDetail?> readStoredMatchDetail(String id) async {
    reads.add(id);
    return null;
  }
}

Snapshot _day(DateTime date) => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-10-31T18:00:00Z',
  'teams': [
    {'id': 'fb_team_home', 'name': 'Local sintético'},
    {'id': 'fb_team_away', 'name': 'Visitante sintético'},
  ],
  'competitions': [
    {'id': 'fb_comp_test', 'name': 'Liga sintética'},
  ],
  'players': [],
  'standings': [],
  'matches': [
    {
      'id': 'fb_match_day${date.day}',
      'competitionId': 'fb_comp_test',
      'homeTeamId': 'fb_team_home',
      'awayTeamId': 'fb_team_away',
      'startTime': DateTime.utc(
        date.year,
        date.month,
        date.day,
        18,
      ).toIso8601String(),
      'status': 'SCHEDULED',
    },
  ],
});

void main() {
  testWidgets('date change before queued warming never reads the old day', (
    tester,
  ) async {
    final now = DateTime(2026, 10, 31, 12);
    final dio = Dio();
    var http = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          http++;
          handler.reject(DioException(requestOptions: options));
        },
      ),
    );
    final repository = _ObservedStoredRepository(dio);
    final container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repository),
        calendarSnapshotProvider.overrideWith(
          (ref, date) => Stream.value(_day(date)),
        ),
        followsProvider.overrideWith(
          (ref) => Stream.value({'team:fb_team_home'}),
        ),
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
      dio.close(force: true);
    });
    var changed = false;
    // This callback is queued before the loaded feed schedules its own warm
    // callback. Simulate a date gesture in that exact post-frame interval.
    void changeBeforeWarm(Duration _) {
      if (find
          .byKey(const ValueKey('match-row-fb_match_day31'))
          .evaluate()
          .isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback(changeBeforeWarm);
        return;
      }
      changed = true;
      final swipe = tester.widget<GestureDetector>(
        find.byKey(const ValueKey('matches-date-swipe')),
      );
      swipe.onHorizontalDragEnd!(
        DragEndDetails(
          primaryVelocity: -600,
          velocity: const Velocity(pixelsPerSecond: Offset(-600, 0)),
        ),
      );
    }

    WidgetsBinding.instance.addPostFrameCallback(changeBeforeWarm);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: MatchesScreen(now: () => now)),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(changed, isTrue);
    expect(repository.reads, isNot(contains('fb_match_day31')));
    expect(repository.reads, ['fb_match_day1']);
    expect(http, 0);
  });
}

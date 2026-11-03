import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/matches_screen.dart';

class _StoredOnlyRepository extends ApiRepository {
  _StoredOnlyRepository(super.dio);
  final reads = <String>[];
  final frames = <Duration>[];
  var active = 0;
  var peak = 0;
  @override
  Future<MatchDetail?> readStoredMatchDetail(String id) async {
    reads.add(id);
    frames.add(SchedulerBinding.instance.currentFrameTimeStamp);
    active++;
    if (active > peak) peak = active;
    await Future<void>.value();
    active--;
    return null;
  }
}

Snapshot _fixtures(
  DateTime date,
  int count, {
  bool redirected = false,
}) => Snapshot({
  if (redirected) 'entityRedirects': {'fb_team_alias': 'fb_team_followed'},
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-11-03T18:00:00Z',
  'teams': [
    {'id': 'fb_team_followed', 'name': 'Followed fixture team'},
    {'id': 'fb_team_other', 'name': 'Other fixture team'},
  ],
  'competitions': [
    {'id': 'fb_comp_fixture', 'name': 'Fixture league'},
  ],
  'players': [],
  'standings': [],
  'matches': [
    for (var i = 0; i < count; i++)
      {
        'id': 'fb_match_${date.day}_$i',
        'competitionId': 'fb_comp_fixture',
        'homeTeamId': redirected ? 'fb_team_alias' : 'fb_team_followed',
        'awayTeamId': 'fb_team_other',
        'startTime': DateTime.utc(
          date.year,
          date.month,
          date.day,
          12 + i,
        ).toIso8601String(),
        // Distinct finished scores make these actual different stored fixtures.
        'status': 'VERIFIED', 'score': {'home': i, 'away': 0},
      },
  ],
});

void main() {
  for (final redirected in [false, true]) {
    for (final count in [5, 12]) {
      testWidgets(
        'favorite disk warming completes bounded batches for $count fixtures redirected=$redirected',
        (tester) async {
          final now = DateTime(2026, 11, 3, 12);
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
          final repository = _StoredOnlyRepository(dio);
          final container = ProviderContainer(
            overrides: [
              repositoryProvider.overrideWithValue(repository),
              calendarSnapshotProvider.overrideWith(
                (ref, date) => Stream.value(
                  _fixtures(date, count, redirected: redirected),
                ),
              ),
              followsProvider.overrideWith(
                (ref) => Stream.value({'team:fb_team_followed'}),
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
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(home: MatchesScreen(now: () => now)),
            ),
          );
          await tester.pumpAndSettle();
          expect(repository.reads.length, count < 8 ? count : 8);
          expect(repository.reads.toSet().length, repository.reads.length);
          expect(repository.peak, lessThanOrEqualTo(2));
          final batches = <Duration, int>{};
          for (final frame in repository.frames) {
            batches.update(frame, (count) => count + 1, ifAbsent: () => 1);
          }
          expect(batches.values.every((count) => count <= 2), isTrue);
          // A different day shares the same eight-read session budget.
          for (var day = 0; day < 2; day++) {
            final swipe = tester.widget<GestureDetector>(
              find.byKey(const ValueKey('matches-date-swipe')),
            );
            swipe.onHorizontalDragEnd!(
              DragEndDetails(
                velocity: const Velocity(pixelsPerSecond: Offset(-600, 0)),
                primaryVelocity: -600,
              ),
            );
            await tester.pumpAndSettle();
            expect(repository.reads, hasLength(8));
          }
          expect(http, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

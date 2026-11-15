import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/matches_screen.dart';

class _StoredCalendar implements FootballRepository {
  final dates = <DateTime>[];
  final now = DateTime(2026, 11, 2, 12);

  Snapshot get data => Snapshot({
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': '2026-11-02T18:00:00Z',
    'teams': [
      {'id': 'fb_team_home245', 'name': 'Local sintético'},
      {'id': 'fb_team_away245', 'name': 'Visitante sintético'},
    ],
    'competitions': [
      {'id': 'fb_comp_synthetic245', 'name': 'Liga sintética', 'country': 'CR'},
    ],
    'players': <Json>[],
    'matches': [
      for (var day = 2; day <= 3; day++)
        {
          'id': 'fb_match_synthetic245_$day',
          'competitionId': 'fb_comp_synthetic245',
          'homeTeamId': 'fb_team_home245',
          'awayTeamId': 'fb_team_away245',
          'startTime': DateTime.utc(2026, 11, day, 18).toIso8601String(),
          'status': 'SCHEDULED',
        },
    ],
    'standings': <Json>[],
  });

  @override
  Future<Snapshot> load() async => data;
  @override
  Future<Snapshot> loadDate(DateTime date) async {
    dates.add(date);
    return data;
  }

  @override
  Future<MatchDetail> loadMatchDetail(String id) async => MatchDetail.empty(id);
}

void main() {
  testWidgets('selecting the same date preserves collapsed leagues and reads', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _StoredCalendar();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repositoryProvider.overrideWithValue(repository),
          liveMatchUpdatesProvider.overrideWith(
            (ref) => Stream.value(const <String, LiveMatchUpdate>{}),
          ),
          preferenceProvider.overrideWith(
            (ref) => Stream.value(
              const CountryPreference(
                detectedCountry: 'CR',
                selectedCountry: 'CR',
                bootstrapDismissed: true,
              ),
            ),
          ),
          followsProvider.overrideWith((ref) => Stream.value(<String>{})),
          temporaryInterestsProvider.overrideWith(
            (ref) => Stream.value(<String>{}),
          ),
        ],
        child: MaterialApp(home: MatchesScreen(now: () => repository.now)),
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.byKey(
      const ValueKey('competition-toggle-fb_comp_synthetic245'),
    );
    expect(find.byType(FeedMatchRow), findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byType(FeedMatchRow), findsNothing);
    final firstReads = repository.dates.length;
    await tester.tap(find.text('HOY'));
    await tester.pumpAndSettle();
    expect(find.byType(FeedMatchRow), findsNothing);
    expect(repository.dates.length, firstReads);

    // A genuinely new day still expands its groups as before.
    await tester.tap(find.text('MAÑANA'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('match-row-fb_match_synthetic245_3')),
      findsOneWidget,
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byType(FeedMatchRow), findsNothing);
    final nextReads = repository.dates.length;
    // Repeat on an explicit date, not only the implicit initial "today".
    await tester.tap(find.text('MAÑANA'));
    await tester.pumpAndSettle();
    expect(find.byType(FeedMatchRow), findsNothing);
    expect(repository.dates.length, nextReads);
    expect(tester.takeException(), isNull);
  });
}

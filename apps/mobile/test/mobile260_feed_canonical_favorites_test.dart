import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/matches_screen.dart';

class _FixtureRepository implements FootballRepository {
  _FixtureRepository(this.data);
  final Snapshot data;
  @override
  Future<Snapshot> load() async => data;
  @override
  Future<Snapshot> loadDate(DateTime date) async => data;
  @override
  Future<MatchDetail> loadMatchDetail(String id) async => MatchDetail.empty(id);
}

void main() {
  for (final homeFollowed in [true, false]) {
    for (final twins in [false, true]) {
      testWidgets(
        "canonical favorite matches redirected $homeFollowed twins=$twins",
        (tester) async {
          tester.view.physicalSize = const Size(400, 1200);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final now = DateTime(2026, 11, 3, 12);
          final data = Snapshot({
            'schemaVersion': 1,
            'demo': false,
            'updatedAt': '2026-11-03T18:00:00Z',
            'entityRedirects': {'fb_team_old': 'fb_team_canonical'},
            'teams': [
              {'id': 'fb_team_canonical', 'name': 'Canonical team'},
              {'id': 'fb_team_other', 'name': 'Other team'},
              {'id': 'fb_team_homonym', 'name': 'Canonical team'},
            ],
            'competitions': [
              {'id': 'fb_comp_fixture', 'name': 'Fixture league'},
            ],
            'players': [],
            'standings': [],
            'matches': [
              if (twins)
                {
                  'id': 'fb_match_ghost',
                  'competitionId': 'fb_comp_fixture',
                  'homeTeamId': homeFollowed
                      ? 'fb_team_canonical'
                      : 'fb_team_other',
                  'awayTeamId': homeFollowed
                      ? 'fb_team_other'
                      : 'fb_team_canonical',
                  'startTime': '2026-11-03T18:00:00Z',
                  'status': 'SCHEDULED',
                },
              {
                'id': 'fb_match_redirected',
                'competitionId': 'fb_comp_fixture',
                'homeTeamId': homeFollowed ? 'fb_team_old' : 'fb_team_other',
                'awayTeamId': homeFollowed ? 'fb_team_other' : 'fb_team_old',
                'startTime': '2026-11-03T18:00:00Z',
                'status': 'VERIFIED',
                'score': {'home': 1, 'away': 0},
              },
              {
                'id': 'fb_match_homonym',
                'competitionId': 'fb_comp_fixture',
                'homeTeamId': 'fb_team_homonym',
                'awayTeamId': 'fb_team_other',
                'startTime': '2026-11-03T19:00:00Z',
                'status': 'VERIFIED',
                'score': {'home': 2, 'away': 0},
              },
            ],
          });
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                repositoryProvider.overrideWithValue(_FixtureRepository(data)),
                calendarSnapshotProvider.overrideWith(
                  (ref, date) => Stream.value(data),
                ),
                followsProvider.overrideWith(
                  (ref) => Stream.value({'team:fb_team_canonical'}),
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
                liveMatchUpdatesProvider.overrideWith(
                  (ref) => Stream.value({}),
                ),
              ],
              child: MaterialApp(home: MatchesScreen(now: () => now)),
            ),
          );
          await tester.pumpAndSettle();
          final favorites = find.byKey(
            const ValueKey('feed-section-favorite-fb_comp_fixture'),
          );
          final league = find.byKey(
            const ValueKey('feed-section-competition-fb_comp_fixture'),
          );
          final redirected = find.byKey(
            const ValueKey('match-row-fb_match_redirected'),
          );
          final homonym = find.byKey(
            const ValueKey('match-row-fb_match_homonym'),
          );
          expect(
            find.descendant(of: favorites, matching: redirected),
            findsOneWidget,
          );
          expect(
            find.descendant(of: league, matching: redirected),
            findsOneWidget,
          );
          expect(
            find.descendant(of: favorites, matching: homonym),
            findsNothing,
          );
          expect(
            find.descendant(of: league, matching: homonym),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('match-row-fb_match_ghost')),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

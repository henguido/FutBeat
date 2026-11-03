import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/matches_screen.dart';

class _Calendar implements FootballRepository {
  _Calendar(this.data);
  final Snapshot data;
  @override
  Future<Snapshot> load() async => data;
  @override
  Future<Snapshot> loadDate(DateTime date) async => data;
  @override
  Future<MatchDetail> loadMatchDetail(String id) async => MatchDetail.empty(id);
}

Snapshot _data(String metadata) => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-11-03T18:00:00Z',
  'entityRedirects': {
    'fb_comp_old1': 'fb_comp_canonical',
    'fb_comp_old2': 'fb_comp_canonical',
  },
  'competitions': [
    if (metadata != 'aliases')
      {'id': 'fb_comp_canonical', 'name': 'Canonical league'},
    if (metadata != 'canonical') ...[
      {'id': 'fb_comp_old1', 'name': 'Old league reference1'},
      {'id': 'fb_comp_old2', 'name': 'Old league reference2'},
    ],
  ],
  'teams': [
    for (final id in ['a', 'b', 'c', 'd'])
      {'id': 'fb_team_$id', 'name': 'Team $id'},
  ],
  'players': [],
  'standings': [],
  'matches': [
    for (var i = 0; i < 2; i++)
      {
        'id': 'fb_match_${i + 1}',
        'competitionId': 'fb_comp_old${i + 1}',
        'homeTeamId': i == 0 ? 'fb_team_a' : 'fb_team_c',
        'awayTeamId': i == 0 ? 'fb_team_b' : 'fb_team_d',
        'startTime': '2026-11-03T18:00:00Z',
        'status': 'VERIFIED',
        'score': {'home': 1, 'away': 0},
      },
  ],
});
void main() {
  for (final metadata in ['canonical', 'both', 'aliases']) {
    test(
      'canonical competition ordering retains redirected fixtures metadata=$metadata',
      () {
        final data = _data(metadata);
        expect(data.matches, hasLength(2));
        final groups = orderMatchCompetitions(
          data: data,
          matches: data.matches,
          follows: {},
        );
        expect(groups.map((c) => c.id), ['fb_comp_canonical']);
      },
    );
    testWidgets(
      'redirected league fixtures remain visible in one canonical group metadata=$metadata',
      (tester) async {
        tester.view.physicalSize = const Size(400, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final data = _data(metadata);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              repositoryProvider.overrideWithValue(_Calendar(data)),
              calendarSnapshotProvider.overrideWith(
                (ref, date) => Stream.value(data),
              ),
              followsProvider.overrideWith(
                (ref) => Stream.value(<String>{
                  if (metadata == 'aliases') 'team:fb_team_a',
                }),
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
            child: MaterialApp(
              home: MatchesScreen(now: () => DateTime(2026, 11, 3, 12)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byType(FeedMatchRow),
          findsNWidgets(metadata == 'aliases' ? 3 : 2),
        );
        expect(
          find.byType(CompetitionMatchGroupCard),
          findsNWidgets(metadata == 'aliases' ? 2 : 1),
        );
        expect(
          find.byKey(
            const ValueKey('feed-section-competition-fb_comp_canonical'),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

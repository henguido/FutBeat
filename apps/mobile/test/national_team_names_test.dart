import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/relevance.dart';
import 'package:futbeat/features/matches/matches_screen.dart';
import 'package:futbeat/features/onboarding/onboarding_screen.dart';

// National teams arrive with the provider's English name plus the server's
// `nationalTeamCode` / `nationalTeamSuffix`; every screen shows the Spanish
// country name through one resolver.

Entity _team(String id, String name, [Map<String, dynamic> extra = const {}]) =>
    Entity({'id': id, 'name': name, 'country': '', ...extra});

Entity _national(String id, String name, String code, [String? suffix]) =>
    _team(id, name, {'nationalTeamCode': code, 'nationalTeamSuffix': ?suffix});

void main() {
  test('category labels: age groups and women', () {
    expect(nationalTeamCategoryLabel(null), '');
    expect(nationalTeamCategoryLabel(''), '');
    expect(nationalTeamCategoryLabel('U19'), 'Sub-19');
    expect(nationalTeamCategoryLabel('W'), 'Femenino');
    expect(nationalTeamCategoryLabel('U20 W'), 'Sub-20 Femenino');
    expect(nationalTeamCategoryLabel('u17 w'), 'Sub-17 Femenino');
    expect(nationalTeamCategoryLabel('Reserves'), isNull);
  });

  test(
    'teamDisplayName localizes national teams and keeps everything else',
    () {
      expect(
        _national('t1', 'Poland U19', 'PL', 'U19').displayName,
        'Polonia Sub-19',
      );
      expect(
        _national('t2', 'Kazakhstan U19', 'KZ', 'U19').displayName,
        'Kazajistán Sub-19',
      );
      expect(_national('t3', 'Netherlands', 'NL').displayName, 'Países Bajos');
      expect(_national('t4', 'Azerbaijan', 'AZ').displayName, 'Azerbaiyán');
      expect(_national('t5', 'Greece', 'GR').displayName, 'Grecia');
      expect(
        _national('t6', 'Netherlands W', 'NL', 'W').displayName,
        'Países Bajos Femenino',
      );
      expect(
        _national('t7', 'Spain U20 Women', 'ES', 'U20 W').displayName,
        'España Sub-20 Femenino',
      );
      expect(
        _national('t8', 'England U21', 'GB-ENG', 'U21').displayName,
        'Inglaterra Sub-21',
      );
      // The provider name stays the stored name.
      expect(_national('t1', 'Poland U19', 'PL', 'U19').name, 'Poland U19');

      // Fallbacks: clubs, unknown codes and unknown categories.
      expect(_team('c1', 'Monaco').displayName, 'Monaco');
      expect(_national('c2', 'Atlantis', 'ZZ').displayName, 'Atlantis');
      expect(
        _national('c3', 'Poland Reserves', 'PL', 'Reserves').displayName,
        'Poland Reserves',
      );
      // A countryCode alone (clubs carry one too) never renames a team.
      expect(
        _team('c4', 'Saprissa', {'countryCode': 'CR'}).displayName,
        'Saprissa',
      );
      // The Explore contract (isNationalTeam + countryCode) is understood too.
      expect(
        _team('t9', 'Costa Rica', {
          'isNationalTeam': true,
          'countryCode': 'CR',
        }).displayName,
        'Costa Rica',
      );
      expect(
        _team('t10', 'Panama', {
          'isNationalTeam': true,
          'countryCode': 'PA',
        }).displayName,
        'Panamá',
      );
      expect(
        onboardingEntityName(
          _team('t10', 'Panama', {'isNationalTeam': true, 'countryCode': 'PA'}),
        ),
        'Panamá',
      );
    },
  );

  test('national teams are found by their Spanish name', () {
    final poland = _national('t1', 'Poland U19', 'PL', 'U19');
    final club = _team('c1', 'Polonia Warszawa U19');
    expect(poland.matches('polonia'), isTrue);
    expect(poland.matches('Poland'), isTrue);
    expect(poland.initials, 'PS');

    final data = _snapshot([poland, club]);
    final ranked = rankSearchEntities(
      data: data,
      entities: data.teams,
      type: 'team',
      query: 'Polonia Sub-19',
      follows: const {},
    );
    expect(ranked.first.id, 't1');
  });

  testWidgets('Partidos feed card shows Spanish national-team names', (
    tester,
  ) async {
    final today = costaRicaNow();
    final data = _snapshot(
      [
        _national('fb_team_pl19', 'Poland U19', 'PL', 'U19'),
        _national('fb_team_kz19', 'Kazakhstan U19', 'KZ', 'U19'),
        _national('fb_team_nl', 'Netherlands', 'NL'),
        _team('fb_team_club', 'Monaco'),
      ],
      matches: [
        _match('fb_match_1', 'fb_team_pl19', 'fb_team_kz19', today, 18),
        _match('fb_match_2', 'fb_team_nl', 'fb_team_club', today, 20),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repositoryProvider.overrideWithValue(_Repository(data)),
          liveMatchUpdatesProvider.overrideWith(
            (ref) => Stream.value(const <String, LiveMatchUpdate>{}),
          ),
          preferenceProvider.overrideWith(
            (ref) => Stream.value(
              const CountryPreference(
                detectedCountry: 'CR',
                selectedCountry: null,
                bootstrapDismissed: true,
              ),
            ),
          ),
          followsProvider.overrideWith((ref) => Stream.value(<String>{})),
          temporaryInterestsProvider.overrideWith(
            (ref) => Stream.value(<String>{}),
          ),
        ],
        child: const MaterialApp(home: MatchesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Polonia Sub-19'), findsOneWidget);
    expect(find.text('Kazajistán Sub-19'), findsOneWidget);
    expect(find.text('Países Bajos'), findsOneWidget);
    expect(find.text('Monaco'), findsOneWidget);
    for (final english in ['Poland U19', 'Kazakhstan U19', 'Netherlands']) {
      expect(find.text(english), findsNothing, reason: english);
    }
    expect(tester.takeException(), isNull);
  });
}

class _Repository implements FootballRepository {
  _Repository(this.snapshot);
  final Snapshot snapshot;
  @override
  Future<Snapshot> load() async => snapshot;

  @override
  Future<Snapshot> loadDate(DateTime date) async => snapshot;

  @override
  Future<MatchDetail> loadMatchDetail(String id) async => MatchDetail.empty(id);
}

Map<String, dynamic> _match(
  String id,
  String home,
  String away,
  DateTime today,
  int hour,
) => {
  'id': id,
  'competitionId': 'fb_comp_youth',
  'homeTeamId': home,
  'awayTeamId': away,
  'startTime': DateTime.utc(
    today.year,
    today.month,
    today.day,
    hour + 6,
  ).toIso8601String(),
  'status': 'SCHEDULED',
  'minute': null,
  'score': null,
  'events': <dynamic>[],
  'statistics': <dynamic>[],
};

Snapshot _snapshot(
  List<Entity> teams, {
  List<Map<String, dynamic>> matches = const [],
}) => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': DateTime.now().toUtc().toIso8601String(),
  'coverage': {'partial': false},
  'freshness': {'stale': false},
  'competitions': [
    {'id': 'fb_comp_youth', 'name': 'Youth Qualification', 'country': ''},
  ],
  'teams': [for (final team in teams) team.json],
  'players': <dynamic>[],
  'matches': matches,
  'standings': <dynamic>[],
});

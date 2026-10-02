import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/countries.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/push.dart';
import 'package:futbeat/features/matches/matches_screen.dart';
import 'package:futbeat/features/onboarding/onboarding_screen.dart';

// Fixtures mirror the QA device report (country CR): the catalog lists
// European national teams with English names, region codes in raw `country`
// fields, and the local league below big global competitions by relevance.
Map<String, dynamic> _competition(
  String id,
  String name, {
  String? country,
  String? countryCode,
  int relevance = 100,
  bool global = false,
  bool primary = false,
}) => {
  'id': id,
  'name': name,
  'country': ?country,
  'countryCode': ?countryCode,
  'relevanceScore': relevance,
  'isGlobalRelevant': global,
  if (primary) 'isPrimaryDomestic': true,
  if (primary) 'domesticTier': 1,
};

Snapshot _catalog({bool countryLens = true, bool? primaryLeague}) => Snapshot(
  _catalogJson(countryLens: countryLens, primaryLeague: primaryLeague),
);

/// [countryLens]: the server's country Explore (national team, league clubs
/// and the competition domestic contract). [primaryLeague] overrides only the
/// league's primary flag.
Map<String, dynamic> _catalogJson({
  bool countryLens = true,
  bool? primaryLeague,
}) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-10-01T12:00:00Z',
  'competitions': [
    _competition(
      'c_nations',
      'UEFA Nations League',
      country: 'eurocups',
      countryCode: 'EUROPE',
      relevance: 910,
      global: true,
    ),
    _competition('c_world', 'Club Friendlies', country: 'intl', relevance: 120),
    _competition(
      'c_epl',
      'Premier League',
      country: 'England',
      countryCode: 'GB-ENG',
      relevance: 930,
      global: true,
      primary: true,
    ),
    _competition(
      'c_es',
      'Primera División ES',
      country: 'Spain',
      countryCode: 'ES',
      relevance: 920,
      global: true,
      primary: true,
    ),
    _competition(
      'c_local_cup',
      'Local Cup',
      country: 'Costa Rica',
      countryCode: 'CR',
      relevance: 700,
    ),
    _competition(
      'c_local',
      'Local First Division',
      country: 'Costa Rica',
      countryCode: 'CR',
      relevance: 660,
      // Older servers do not send the domestic contract for catalog entries.
      primary: primaryLeague ?? countryLens,
    ),
  ],
  'teams': [
    // Server order: the global activity list first, as reported on device.
    {
      'id': 't_azerbaijan',
      'name': 'Azerbaijan',
      'countryCode': 'EUROPE',
      'competitionId': 'c_nations',
      'relevanceScore': 910,
    },
    {
      'id': 't_greece',
      'name': 'Greece',
      'countryCode': 'EUROPE',
      'competitionId': 'c_nations',
      'relevanceScore': 910,
    },
    {
      'id': 't_es_club',
      'name': 'Spanish Club',
      'countryCode': 'ES',
      'competitionId': 'c_es',
      'relevanceScore': 920,
    },
    {
      'id': 't_other',
      'name': 'Other Club',
      'countryCode': 'MX',
      'competitionId': 'c_unknown',
      'relevanceScore': 100,
    },
    {
      'id': 't_local_cup_side',
      'name': 'Local Second Tier',
      'countryCode': 'CR',
      'competitionId': 'c_local_cup',
      'relevanceScore': 700,
    },
    if (countryLens) ...[
      {
        'id': 't_local_nation',
        'name': 'Costa Rica',
        'countryCode': 'CR',
        'isNationalTeam': true,
        'competitionId': 'c_regional',
        'relevanceScore': 400,
      },
      {
        // Last seen in a regional cup, but a club of the primary league.
        'id': 't_local_b',
        'name': 'Local Club B',
        'countryCode': 'CR',
        'isPrimaryDomesticClub': true,
        'competitionId': 'c_regional',
        'relevanceScore': 660,
      },
    ],
    {
      'id': 't_local_a',
      'name': 'Local Club A',
      'countryCode': 'CR',
      'competitionId': 'c_local',
      'relevanceScore': 660,
    },
  ],
  'players': <dynamic>[],
  'matches': <dynamic>[],
  'standings': <dynamic>[],
};

List<String> _ids(Iterable<Entity> entities) => [
  for (final entity in entities) entity.id,
];

void main() {
  group('QA-1 team suggestions follow the selected country', () {
    test('national team, primary league clubs, other local, global, rest', () {
      final data = _catalog();
      final ranked = rankOnboardingEntities(
        'team',
        data.teams,
        'CR',
        competition: data.competition,
      );
      expect(_ids(ranked), [
        't_local_nation',
        't_local_b',
        't_local_a',
        't_local_cup_side',
        't_azerbaijan',
        't_greece',
        't_es_club',
        't_other',
      ]);
      // Never filters: every global suggestion is still offered.
      expect(ranked.toSet(), data.teams.toSet());
    });

    test('older servers: local teams still lead the global list', () {
      final data = _catalog(countryLens: false);
      final ranked = rankOnboardingEntities(
        'team',
        data.teams,
        'CR',
        competition: data.competition,
      );
      // Without the domestic contract both are plain local teams, kept in
      // the server order.
      expect(_ids(ranked).take(3), [
        't_local_cup_side',
        't_local_a',
        't_azerbaijan',
      ]);
    });

    test('a club of the primary league is found from competition metadata', () {
      final data = _catalog(countryLens: false, primaryLeague: true);
      final ranked = rankOnboardingEntities(
        'team',
        data.teams,
        'CR',
        competition: data.competition,
      );
      expect(_ids(ranked).take(2), ['t_local_a', 't_local_cup_side']);
    });

    test('the same rules serve any country (nothing is hardcoded)', () {
      final data = _catalog();
      expect(
        _ids(
          rankOnboardingEntities(
            'team',
            data.teams,
            'ES',
            competition: data.competition,
          ),
        ).first,
        't_es_club',
      );
      // No country: the server order is kept as is.
      expect(_ids(rankOnboardingEntities('team', data.teams, null)).take(3), [
        't_azerbaijan',
        't_greece',
        't_es_club',
      ]);
    });

    test('a typed search keeps the backend order (global search intact)', () {
      final data = _catalog();
      expect(
        _ids(onboardingEntitiesForQuery('team', data.teams, 'CR', 'gr')),
        _ids(data.teams),
      );
    });

    test('a flagged national team shows its localized country name', () {
      final team = Entity({
        'id': 't',
        'name': 'Panama',
        'countryCode': 'PA',
        'isNationalTeam': true,
      });
      expect(onboardingEntityName(team), 'Panamá');
      // Not repeated as its own subtitle.
      expect(onboardingEntitySubtitle(team), isNull);
      // Unflagged teams keep their name, even if it reads like a country.
      expect(
        onboardingEntityName(Entity({'id': 'x', 'name': 'Panama'})),
        'Panama',
      );
    });

    test('Explore asks the server for the country lens', () async {
      final requests = <Map<String, dynamic>?>[];
      final dio = Dio();
      addTearDown(dio.close);
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.path, '/v1/explore');
            requests.add(
              options.queryParameters.isEmpty
                  ? null
                  : Map.of(options.queryParameters),
            );
            handler.resolve(
              Response(requestOptions: options, data: _catalogJson()),
            );
          },
        ),
      );
      final repository = ApiRepository(dio);
      await repository.loadExplore(country: 'cr');
      await repository.loadExplore(country: 'CR');
      await repository.loadExplore(country: 'EUROPE');
      await repository.loadExplore();
      // Per-country cache; regions and no country use the global list.
      expect(requests, [
        {'country': 'CR'},
        null,
      ]);
    });
  });

  group('QA-2 country and region labels are Spanish, never raw codes', () {
    test('canonical codes win over provider strings', () {
      expect(countryLabel('EUROPE', 'eurocups'), 'Europa');
      expect(countryLabel('GB-ENG', 'England'), 'Inglaterra');
      expect(countryLabel('ES', 'Spain'), 'España');
      expect(countryLabel('CAMERICA', 'CONCACAF'), 'Centroamérica');
      expect(countryLabel('WORLD', 'World'), 'Internacional');
    });

    test('provider region tokens map to the same labels', () {
      expect(countryLabel(null, 'eurocups'), 'Europa');
      expect(countryLabel(null, 'intl'), 'Internacional');
      expect(countryLabel(null, 'Worldcup'), 'Internacional');
      expect(countryLabel(null, 'CONMEBOL'), 'Sudamérica');
      expect(countryLabel(null, 'cr'), 'Costa Rica');
    });

    test('unknown codes are hidden; human names are a last resort', () {
      for (final raw in ['XYZ', 'world_cup', 'abc', 'EU-1', '', '  ']) {
        expect(countryLabel(null, raw), isNull, reason: raw);
      }
      expect(countryLabel('ZZZ', null), isNull);
      expect(countryLabel(null, 'Costa Rica'), 'Costa Rica');
      expect(countryLabel(null, "Côte d'Ivoire"), "Côte d'Ivoire");
    });

    test('every selectable country resolves to its display name', () {
      for (final code in selectableCountryCodes) {
        expect(countryLabel(code), countryDisplayName(code), reason: code);
      }
    });

    testWidgets('onboarding competition subtitles are localized', (
      tester,
    ) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await _pumpOnboarding(tester, db);
      await tester.tap(find.text('Continuar'));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.tap(find.text('Continuar'));
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('Competiciones'), findsOneWidget);
      for (final raw in ['eurocups', 'intl', 'England', 'Spain']) {
        expect(find.text(raw), findsNothing, reason: raw);
      }
      expect(find.text('Europa'), findsOneWidget);
      expect(find.text('Inglaterra'), findsOneWidget);
      expect(find.text('España'), findsOneWidget);
      expect(find.text('Internacional'), findsOneWidget);
    });

    testWidgets('Partidos group header shows the localized region', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            repositoryProvider.overrideWithValue(
              _FeedRepository(_feedSnapshot()),
            ),
            liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
            preferenceProvider.overrideWith(
              (ref) => Stream.value(
                const CountryPreference(
                  detectedCountry: null,
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
          child: const MaterialApp(home: MatchesScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('UEFA Nations League'), findsOneWidget);
      expect(find.text('eurocups'), findsNothing);
      expect(find.text('Europa'), findsOneWidget);
      expect(find.text('intl'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('QA-3 competitions use the Partidos country-aware order', () {
    test('primary league first, then global, then secondary national', () {
      final ranked = rankOnboardingEntities(
        'competition',
        _catalog().competitions,
        'CR',
      );
      expect(_ids(ranked), [
        'c_local',
        'c_epl',
        'c_es',
        'c_nations',
        'c_local_cup',
        'c_world',
      ]);
    });

    test('identical to the feed order for the same competitions', () {
      final data = _catalog();
      final feed = orderMatchCompetitions(
        data: data,
        matches: [
          for (final competition in data.competitions)
            FootballMatch({
              'id': 'm_${competition.id}',
              'competitionId': competition.id,
              'homeTeamId': 'h',
              'awayTeamId': 'a',
              'startTime': '2026-10-01T18:00:00Z',
              'status': 'SCHEDULED',
            }),
        ],
        follows: const {},
        selectedCountry: 'CR',
      );
      expect(
        _ids(rankOnboardingEntities('competition', data.competitions, 'CR')),
        _ids(feed),
      );
    });

    test('another country lifts its own primary league', () {
      expect(
        _ids(
          rankOnboardingEntities('competition', _catalog().competitions, 'ES'),
        ).first,
        'c_es',
      );
      expect(
        _ids(
          rankOnboardingEntities('competition', _catalog().competitions, 'GB'),
        ).first,
        'c_epl',
      );
    });

    testWidgets('onboarding lists the primary league first', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await _pumpOnboarding(tester, db);
      await tester.tap(find.text('Continuar'));
      await tester.pump(const Duration(milliseconds: 20));
      // Teams step: the national team leads, foreign national teams follow.
      final nation = tester.getTopLeft(find.text('Costa Rica').first).dy;
      expect(nation, lessThan(tester.getTopLeft(find.text('Azerbaijan')).dy));
      await tester.tap(find.text('Continuar'));
      await tester.pump(const Duration(milliseconds: 20));
      expect(
        tester.getTopLeft(find.text('Local First Division')).dy,
        lessThan(tester.getTopLeft(find.text('Premier League')).dy),
      );
    });
  });
}

Future<void> _pumpOnboarding(WidgetTester tester, AppDatabase database) async {
  tester.view.physicalSize = const Size(390, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        detectedCountryProvider.overrideWithValue(null),
        followsProvider.overrideWith((ref) => Stream.value(<String>{})),
        preferenceProvider.overrideWith(
          (ref) => Stream.value(
            const CountryPreference(
              detectedCountry: null,
              selectedCountry: 'CR',
              bootstrapDismissed: false,
            ),
          ),
        ),
        exploreSnapshotProvider.overrideWith((ref) => Stream.value(_catalog())),
        profileSettingsProvider.overrideWith(
          (ref) async => const UserProfileSettings(),
        ),
      ],
      child: const MaterialApp(home: OnboardingScreen()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

class _FeedRepository implements FootballRepository {
  _FeedRepository(this.snapshot);
  final Snapshot snapshot;
  @override
  Future<Snapshot> load() async => snapshot;

  @override
  Future<Snapshot> loadDate(DateTime date) async => snapshot;

  @override
  Future<MatchDetail> loadMatchDetail(String id) async => MatchDetail.empty(id);
}

Snapshot _feedSnapshot() {
  final today = costaRicaNow();
  final start = DateTime.utc(
    today.year,
    today.month,
    today.day,
    18,
  ).toIso8601String();
  return Snapshot({
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
    'coverage': {'partial': false},
    'freshness': {'stale': false},
    'competitions': [
      _competition(
        'c_nations',
        'UEFA Nations League',
        country: 'eurocups',
        countryCode: 'EUROPE',
        relevance: 910,
        global: true,
      ),
      _competition('c_world', 'Club Friendlies', country: 'intl'),
    ],
    'teams': [
      {'id': 't_az', 'name': 'Azerbaijan'},
      {'id': 't_gr', 'name': 'Greece'},
      {'id': 't_a', 'name': 'Club A'},
      {'id': 't_b', 'name': 'Club B'},
    ],
    'players': <dynamic>[],
    'matches': [
      for (final (id, competition, home, away) in [
        ('m1', 'c_nations', 't_az', 't_gr'),
        ('m2', 'c_world', 't_a', 't_b'),
      ])
        {
          'id': id,
          'competitionId': competition,
          'homeTeamId': home,
          'awayTeamId': away,
          'startTime': start,
          'status': 'SCHEDULED',
          'score': null,
          'events': <dynamic>[],
          'statistics': <dynamic>[],
        },
    ],
    'standings': <dynamic>[],
  });
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/matches_screen.dart';

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

Snapshot _snapshot({
  bool costaRicaMatch = true,
  bool includeCup = false,
  String costaRicaStatus = 'SCHEDULED',
  String laLigaStatus = 'SCHEDULED',
}) {
  final today = costaRicaNow();
  String startAt(int hour) => DateTime.utc(
    today.year,
    today.month,
    today.day,
    hour + 6,
  ).toIso8601String();
  Map<String, dynamic> match(
    String id,
    String competitionId,
    String homeId,
    String awayId,
    String status,
    int hour,
  ) => {
    'id': id,
    'competitionId': competitionId,
    'homeTeamId': homeId,
    'awayTeamId': awayId,
    'startTime': startAt(hour),
    'status': status,
    'minute': status == 'LIVE' ? 63 : null,
    'score': status == 'SCHEDULED' ? null : {'home': 1, 'away': 0},
    'events': <dynamic>[],
    'statistics': <dynamic>[],
  };

  return Snapshot({
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
    'coverage': {'partial': false},
    'freshness': {'stale': false},
    'competitions': [
      {
        'id': 'fb_comp_cr',
        'name': 'Liga Promerica',
        'country': 'Costa Rica',
        'countryCode': 'CR',
        'relevanceScore': 660,
        'competitionClass': 'domestic_league',
        'domesticTier': 1,
        'isPrimaryDomestic': true,
      },
      {
        'id': 'fb_comp_laliga',
        'name': 'LaLiga',
        'country': 'Spain',
        'countryCode': 'ES',
        'relevanceScore': 920,
        'isGlobalRelevant': true,
      },
      if (includeCup)
        {
          'id': 'fb_comp_cac',
          'name': 'CONCACAF Central American Cup',
          'country': 'CONCACAF',
          'countryCode': 'CAMERICA',
          'relevanceScore': 700,
          'competitionClass': 'international_club',
          'isGlobalRelevant': true,
        },
    ],
    'teams': [
      {'id': 'fb_team_sap', 'name': 'Saprissa', 'country': 'Costa Rica'},
      {'id': 'fb_team_lda', 'name': 'Alajuelense', 'country': 'Costa Rica'},
      {'id': 'fb_team_betis', 'name': 'Real Betis', 'country': 'Spain'},
      {'id': 'fb_team_getafe', 'name': 'Getafe', 'country': 'Spain'},
      if (includeCup)
        {'id': 'fb_team_mar', 'name': 'Marathón', 'country': 'Honduras'},
      if (includeCup)
        {'id': 'fb_team_x', 'name': 'Equipo X', 'country': 'Guatemala'},
      if (includeCup)
        {'id': 'fb_team_y', 'name': 'Equipo Y', 'country': 'Panama'},
    ],
    'players': <dynamic>[],
    'matches': [
      if (costaRicaMatch)
        match(
          'fb_match_cr',
          'fb_comp_cr',
          'fb_team_sap',
          'fb_team_lda',
          costaRicaStatus,
          12,
        ),
      match(
        'fb_match_es',
        'fb_comp_laliga',
        'fb_team_betis',
        'fb_team_getafe',
        laLigaStatus,
        13,
      ),
      if (includeCup)
        match(
          'fb_match_lda_cup',
          'fb_comp_cac',
          'fb_team_lda',
          'fb_team_mar',
          'SCHEDULED',
          18,
        ),
      if (includeCup)
        match(
          'fb_match_other_cup',
          'fb_comp_cac',
          'fb_team_x',
          'fb_team_y',
          'SCHEDULED',
          20,
        ),
    ],
    'standings': <dynamic>[],
  });
}

Snapshot _largeSnapshot(int matchCount) {
  final today = costaRicaNow();
  final startTime = DateTime.utc(
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
      {
        'id': 'fb_comp_scale',
        'name': 'Liga de escala',
        'country': 'Costa Rica',
        'countryCode': 'CR',
      },
    ],
    'teams': [
      {'id': 'fb_team_home', 'name': 'Local', 'country': 'Costa Rica'},
      {'id': 'fb_team_away', 'name': 'Visita', 'country': 'Costa Rica'},
    ],
    'players': <dynamic>[],
    'matches': [
      for (var i = 0; i < matchCount; i++)
        {
          'id': 'fb_match_scale_$i',
          'competitionId': 'fb_comp_scale',
          'homeTeamId': 'fb_team_home',
          'awayTeamId': 'fb_team_away',
          'startTime': startTime,
          'status': 'SCHEDULED',
          'score': null,
          'events': <dynamic>[],
          'statistics': <dynamic>[],
        },
    ],
    'standings': <dynamic>[],
  });
}

List<String> _ids(
  Snapshot data, {
  Set<String> follows = const {},
  String? selected,
  String? detected = 'CR',
  String mode = CompetitionOrderMode.automatic,
  String preference = CompetitionOrderPreference.countryFirst,
  List<String> pinned = const [],
}) => orderMatchCompetitions(
  data: data,
  matches: data.matches,
  follows: follows,
  selectedCountry: selected,
  detectedCountry: detected,
  orderMode: mode,
  orderPreference: preference,
  pinnedCompetitionIds: pinned,
).map((competition) => competition.id).toList();

void main() {
  testWidgets(
    'unfollow removes your competitions block but keeps its matches despite stale pin',
    (tester) async {
      final follows = StreamController<Set<String>>();
      final data = _snapshot();
      tester.view.physicalSize = const Size(390, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            repositoryProvider.overrideWithValue(_Repository(data)),
            liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
            preferenceProvider.overrideWith(
              (ref) => Stream.value(
                const CountryPreference(
                  detectedCountry: null,
                  selectedCountry: null,
                  bootstrapDismissed: true,
                  competitionOrderMode: CompetitionOrderMode.personalized,
                  pinnedCompetitionIds: ['fb_comp_cr'],
                ),
              ),
            ),
            followsProvider.overrideWith((ref) => follows.stream),
            temporaryInterestsProvider.overrideWith(
              (ref) => Stream.value(<String>{}),
            ),
          ],
          child: const MaterialApp(home: MatchesScreen()),
        ),
      );
      follows.add({'competition:fb_comp_cr'});
      await tester.pumpAndSettle();
      expect(find.text('TUS COMPETICIONES'), findsOneWidget);
      follows.add({});
      await tester.pumpAndSettle();
      expect(find.text('TUS COMPETICIONES'), findsNothing);
      expect(find.text('Saprissa'), findsOneWidget);
      expect(find.text('Alajuelense'), findsOneWidget);
      expect(find.text('Real Betis'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('LaLiga')).dy,
        lessThan(tester.getTopLeft(find.text('Liga Promerica')).dy),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(follows.close);
    },
  );

  test('legacy country and stale pins never change automatic relevance', () {
    final data = _snapshot();
    expect(_ids(data, selected: null, detected: null), [
      'fb_comp_laliga',
      'fb_comp_cr',
    ]);
    expect(_ids(data, selected: 'CR', detected: 'MX'), [
      'fb_comp_laliga',
      'fb_comp_cr',
    ]);
    expect(_ids(data, pinned: ['fb_comp_cr']), [
      'fb_comp_laliga',
      'fb_comp_cr',
    ]);
    expect(
      _ids(
        data,
        pinned: ['fb_comp_cr'],
        mode: CompetitionOrderMode.personalized,
      ),
      ['fb_comp_laliga', 'fb_comp_cr'],
    );
    expect(
      _ids(data, pinned: ['fb_comp_cr'], follows: {'competition:fb_comp_cr'}),
      ['fb_comp_cr', 'fb_comp_laliga'],
    );
    expect(data.matches, hasLength(2));
  });

  test('explicit null editorial fields preserve every ordering group', () {
    final base = _snapshot();
    final competitions = [
      for (final id in [
        'favorite',
        'pinned',
        'primary',
        'global',
        'secondary',
        'rest',
      ])
        {
          'id': id,
          'name': id,
          'countryCode': ['primary', 'secondary'].contains(id) ? 'CR' : null,
          'domesticTier': id == 'primary' ? 1 : null,
          'competitionClass': id == 'global' ? 'international_club' : 'other',
          'relevanceScore': id == 'global' ? 970 : 100,
          'isPrimaryDomestic': id == 'primary',
          'isGlobalRelevant': id == 'global',
          'audienceClass': 'unknown',
          'relevanceSource': id == 'global' ? 'editorial' : 'derived',
        },
    ];
    final data = Snapshot({
      'schemaVersion': 1,
      'demo': false,
      'updatedAt': base.updatedAt.toIso8601String(),
      'competitions': competitions,
      'teams': base.teams.map((item) => item.json).toList(),
      'players': <dynamic>[],
      'matches': [
        for (final competition in competitions)
          {
            ...base.matches.first.json,
            'id': 'match_${competition['id']}',
            'competitionId': competition['id'],
          },
      ],
      'standings': <dynamic>[],
    });
    expect(
      _ids(
        data,
        follows: {'competition:favorite', 'competition:pinned'},
        pinned: ['favorite', 'pinned'],
        mode: CompetitionOrderMode.personalized,
      ),
      ['favorite', 'pinned', 'global', 'primary', 'rest', 'secondary'],
    );
    final unknown = data.competitions.firstWhere((item) => item.id == 'rest');
    expect(unknown.json.containsKey('countryCode'), isTrue);
    expect(unknown.json['countryCode'], isNull);
    expect(unknown.json.containsKey('domesticTier'), isTrue);
    expect(unknown.json['domesticTier'], isNull);
  });

  test('120 competitions and 1200 matches retain every group across ordering modes', () {
    final competitions = [
      for (var i = 0; i < 120; i++)
        {
          'id': 'scale_$i',
          'name': 'Competition $i',
          'countryCode': switch (i % 6) {
            0 || 3 => 'CR',
            1 || 4 => 'JP',
            _ => 'ES',
          },
          'competitionClass': i % 6 == 2
              ? 'international_club'
              : 'domestic_league',
          'isPrimaryDomestic': i % 6 < 2,
          'domesticTier': i % 6 < 2 ? 1 : 2,
          'isGlobalRelevant': i % 6 == 2,
          'relevanceScore': 1000 - i,
        },
    ];
    final data = Snapshot({
      'schemaVersion': 1,
      'demo': false,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'competitions': competitions,
      'teams': [
        {'id': 'home', 'name': 'Home'},
        {'id': 'away', 'name': 'Away'},
      ],
      'players': <dynamic>[],
      'standings': <dynamic>[],
      'matches': [
        for (var i = 0; i < 1200; i++)
          {
            'id': 'match_$i',
            'competitionId': 'scale_${i ~/ 10}',
            'homeTeamId': 'home',
            'awayTeamId': 'away',
            'startTime': '2026-09-21T18:00:00Z',
            'status': 'SCHEDULED',
            'events': <dynamic>[],
            'statistics': <dynamic>[],
          },
      ],
    });
    const follows = {'competition:scale_118', 'competition:scale_119'};
    final before = data.matches.map((match) => match.id).toSet();
    List<String> expected(
      String country, {
      bool globalFirst = false,
      bool custom = false,
    }) {
      return [
        if (custom) ...[
          'scale_119',
          'scale_118',
        ] else ...[
          'scale_118',
          'scale_119',
        ],
        for (var i = 0; i < 118; i++) 'scale_$i',
      ];
    }

    final timer = Stopwatch()..start();
    for (var iteration = 0; iteration < 20; iteration++) {
      for (final country in ['CR', 'JP']) {
        for (final custom in [false, true]) {
          final ids = _ids(
            data,
            follows: follows,
            selected: country,
            mode: custom
                ? CompetitionOrderMode.personalized
                : CompetitionOrderMode.automatic,
            preference: CompetitionOrderPreference.globalFirst,
            pinned: ['scale_119', 'scale_118'],
          );
          expect(ids, expected(country, globalFirst: custom, custom: custom));
          expect(ids.toSet(), competitions.map((c) => c['id']).toSet());
          final displayed = data.matches.where(
            (m) => ids.contains(m.competitionId),
          );
          expect(displayed.length, 1200);
          expect(displayed.map((m) => m.id).toSet(), before);
        }
      }
    }
    timer.stop();
    expect(timer.elapsed, lessThan(const Duration(seconds: 5)));
    expect(data.matches.length, 1200);
  });

  test('supranational scope and high score do not imply global relevance', () {
    final base = _snapshot();
    final data = Snapshot({
      'demo': false,
      'schemaVersion': 1,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'teams': base.teams.map((t) => t.json).toList(),
      'players': <dynamic>[],
      'standings': <dynamic>[],
      'competitions': [
        ...base.competitions.map((c) => c.json),
        {
          'id': 'friendly',
          'name': 'Club Friendlies',
          'countryCode': 'WORLD',
          'competitionClass': 'international_club',
          'relevanceScore': 1000,
        },
      ],
      'matches': [
        ...base.matches.map((m) => m.json),
        {
          ...base.matches.first.json,
          'id': 'friendly_match',
          'competitionId': 'friendly',
        },
      ],
    });
    expect(_ids(data, selected: 'CR'), [
      'friendly',
      'fb_comp_laliga',
      'fb_comp_cr',
    ]);
  });

  test('without follows every competition stays visible', () {
    final data = _snapshot();
    expect(_ids(data), ['fb_comp_laliga', 'fb_comp_cr']);
    expect(data.matches.map((match) => match.id).toSet(), {
      'fb_match_cr',
      'fb_match_es',
    });
  });

  test('a followed competition is promoted but nothing is hidden', () {
    final data = _snapshot();
    expect(_ids(data, follows: {'competition:fb_comp_cr'}), [
      'fb_comp_cr',
      'fb_comp_laliga',
    ]);
    expect(data.matches.length, 2);
  });

  test('following a team never promotes its whole competition', () {
    final data = _snapshot(includeCup: true);
    expect(_ids(data, follows: {'team:fb_team_lda'}), [
      'fb_comp_laliga',
      'fb_comp_cac',
      'fb_comp_cr',
    ]);
  });

  test('legacy country preferences do not change relevance ranking', () {
    expect(_ids(_snapshot(), selected: 'ES'), ['fb_comp_laliga', 'fb_comp_cr']);
    expect(_ids(_snapshot(), detected: 'CR'), ['fb_comp_laliga', 'fb_comp_cr']);
    expect(_ids(_snapshot(), selected: 'CR'), ['fb_comp_laliga', 'fb_comp_cr']);
  });

  test('switching selected countries preserves order and every match', () {
    final data = _snapshot();
    final before = data.matches.map((match) => match.id).toSet();

    expect(_ids(data, selected: 'CR'), ['fb_comp_laliga', 'fb_comp_cr']);
    expect(_ids(data, selected: 'ES'), ['fb_comp_laliga', 'fb_comp_cr']);
    expect(data.matches.map((match) => match.id).toSet(), before);
  });

  test('editorial score outranks domestic and global categories', () {
    final base = _snapshot();
    final raw = <String, dynamic>{
      'schemaVersion': 1,
      'demo': false,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'coverage': {'partial': false},
      'freshness': {'stale': false},
      'competitions': [
        ...base.competitions.map((item) => item.json),
        {
          'id': 'fb_comp_cr_second',
          'name': 'Segunda CR',
          'country': 'Costa Rica',
          'countryCode': 'CR',
          'relevanceScore': 220,
          'competitionClass': 'domestic_league',
          'domesticTier': 2,
        },
        {
          'id': 'fb_comp_other',
          'name': 'Other',
          'country': 'Other',
          'relevanceScore': 300,
        },
      ],
      'teams': base.teams.map((item) => item.json).toList(),
      'players': <dynamic>[],
      'matches': [
        ...base.matches.map((item) => item.json),
        for (final entry in [
          ('second', 'fb_comp_cr_second'),
          ('other', 'fb_comp_other'),
        ])
          {
            'id': 'fb_match_${entry.$1}',
            'competitionId': entry.$2,
            'homeTeamId': 'fb_team_sap',
            'awayTeamId': 'fb_team_lda',
            'startTime': base.matches.first.json['startTime'],
            'status': 'SCHEDULED',
            'score': null,
            'events': <dynamic>[],
            'statistics': <dynamic>[],
          },
      ],
      'standings': <dynamic>[],
    };
    final data = Snapshot(raw);
    expect(_ids(data, selected: 'CR'), [
      'fb_comp_laliga',
      'fb_comp_cr',
      'fb_comp_other',
      'fb_comp_cr_second',
    ]);
  });

  test('personalized pinned order persists above category preference', () {
    final data = _snapshot();
    expect(
      _ids(
        data,
        selected: 'CR',
        follows: {'competition:fb_comp_cr', 'competition:fb_comp_laliga'},
        mode: CompetitionOrderMode.personalized,
        preference: CompetitionOrderPreference.globalFirst,
        pinned: ['fb_comp_laliga', 'fb_comp_cr'],
      ),
      ['fb_comp_laliga', 'fb_comp_cr'],
    );
  });

  test('automatic mode ignores stale personalized pinned order', () {
    final data = _snapshot();
    expect(
      _ids(
        data,
        selected: 'CR',
        follows: {'competition:fb_comp_cr', 'competition:fb_comp_laliga'},
        mode: CompetitionOrderMode.automatic,
        pinned: ['fb_comp_laliga', 'fb_comp_cr'],
      ),
      ['fb_comp_laliga', 'fb_comp_cr'],
    );
  });

  test('status filters still select live, upcoming, and finished games', () {
    final data = _snapshot(costaRicaStatus: 'LIVE', laLigaStatus: 'VERIFIED');
    final today = costaRicaNow();
    expect(data.onDate(today, 'En vivo').map((match) => match.id), [
      'fb_match_cr',
    ]);
    expect(data.onDate(today, 'Finalizados').map((match) => match.id), [
      'fb_match_es',
    ]);
    expect(data.onDate(today, 'Próximos'), isEmpty);
  });

  testWidgets(
    'large match catalogs build only visible cards while preserving all matches',
    (tester) async {
      final data = _largeSnapshot(250);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

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

      expect(data.matches, hasLength(250));
      final builtCards = find.byType(MatchCard).evaluate().length;
      expect(builtCards, greaterThan(0));
      expect(builtCards, lessThan(50));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'followed team matches appear first and the rest of the day stays visible',
    (tester) async {
      final data = _snapshot(includeCup: true);
      tester.view.physicalSize = const Size(390, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
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
            followsProvider.overrideWith(
              (ref) => Stream.value(<String>{'team:fb_team_lda'}),
            ),
            temporaryInterestsProvider.overrideWith(
              (ref) => Stream.value(<String>{}),
            ),
          ],
          child: const MaterialApp(home: MatchesScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('TUS EQUIPOS'), findsOneWidget);
      expect(find.text('TUS COMPETICIONES'), findsNothing);
      expect(find.text('TODOS LOS PARTIDOS'), findsOneWidget);
      expect(find.text('Marathón'), findsOneWidget);
      expect(find.text('Equipo X'), findsOneWidget);
      expect(find.text('Equipo Y'), findsOneWidget);
      expect(find.text('Real Betis'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Marathón')).dy,
        lessThan(tester.getTopLeft(find.text('Equipo X')).dy),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('date strip recenters indefinitely and keeps calendar access', (
    tester,
  ) async {
    final data = _snapshot();
    tester.view.physicalSize = const Size(390, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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

    final today = DateUtils.dateOnly(costaRicaNow());
    String compact(DateTime value) {
      const months = [
        'ENE',
        'FEB',
        'MAR',
        'ABR',
        'MAY',
        'JUN',
        'JUL',
        'AGO',
        'SEP',
        'OCT',
        'NOV',
        'DIC',
      ];
      return '${value.day} ${months[value.month - 1]}';
    }

    final todayFinder = find.text(compact(today));
    final initialCenter = tester.getCenter(todayFinder).dx;

    await tester.tap(find.text('MAÑANA'));
    await tester.pumpAndSettle();

    expect(tester.getCenter(todayFinder).dx, lessThan(initialCenter));
    expect(
      find.text(compact(today.add(const Duration(days: 2)))),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.calendar_month_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a followed competition gets its own block before all matches', (
    tester,
  ) async {
    final data = _snapshot();
    tester.view.physicalSize = const Size(390, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
          followsProvider.overrideWith(
            (ref) => Stream.value(<String>{'competition:fb_comp_cr'}),
          ),
          temporaryInterestsProvider.overrideWith(
            (ref) => Stream.value(<String>{}),
          ),
        ],
        child: const MaterialApp(home: MatchesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('TUS COMPETICIONES'), findsOneWidget);
    expect(find.text('TODOS LOS PARTIDOS'), findsOneWidget);
    expect(find.text('Liga Promerica'), findsOneWidget);
    expect(find.text('LaLiga'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Liga Promerica')).dy,
      lessThan(tester.getTopLeft(find.text('LaLiga')).dy),
    );
    expect(tester.takeException(), isNull);
  });
}

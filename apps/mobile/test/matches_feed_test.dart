import 'dart:async';
import 'dart:collection';

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
    // One team pair per match: the same pair at the same kickoff is a single
    // fixture for the feed and would be listed once.
    'teams': [
      for (var i = 0; i < matchCount; i++) ...[
        {'id': 'fb_team_home_$i', 'name': 'Local $i', 'country': 'Costa Rica'},
        {'id': 'fb_team_away_$i', 'name': 'Visita $i', 'country': 'Costa Rica'},
      ],
    ],
    'players': <dynamic>[],
    'matches': [
      for (var i = 0; i < matchCount; i++)
        {
          'id': 'fb_match_scale_$i',
          'competitionId': 'fb_comp_scale',
          'homeTeamId': 'fb_team_home_$i',
          'awayTeamId': 'fb_team_away_$i',
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

/// Counts every field read the production code performs on a JSON-backed
/// model. Entity/FootballMatch getters are `json[...]` lookups, so this is a
/// deterministic proxy for comparator calls and match scans.
class _CountingJson extends MapView<String, dynamic> {
  _CountingJson(super.map, this._counter);
  final _ReadCounter _counter;
  @override
  dynamic operator [](Object? key) {
    _counter.reads++;
    return super[key];
  }
}

class _ReadCounter {
  int reads = 0;
}

Snapshot _scaleSnapshot(int competitionCount, {_ReadCounter? counter}) {
  Map<String, dynamic> wrap(Map<String, dynamic> json) =>
      counter == null ? json : _CountingJson(json, counter);
  return Snapshot({
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': '2026-09-21T12:00:00Z',
    'competitions': [
      for (var i = 0; i < competitionCount; i++)
        wrap({
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
        }),
    ],
    'teams': [
      {'id': 'home', 'name': 'Home'},
      {'id': 'away', 'name': 'Away'},
    ],
    'players': <dynamic>[],
    'standings': <dynamic>[],
    'matches': [
      for (var i = 0; i < competitionCount * 10; i++)
        wrap({
          'id': 'match_$i',
          'competitionId': 'scale_${i ~/ 10}',
          'homeTeamId': 'home',
          'awayTeamId': 'away',
          'startTime': '2026-09-21T18:00:00Z',
          'status': 'SCHEDULED',
          'events': <dynamic>[],
          'statistics': <dynamic>[],
        }),
    ],
  });
}

List<String> _order(Snapshot data, {required bool custom, required int n}) =>
    orderMatchCompetitions(
      data: data,
      matches: data.matches,
      follows: {'competition:scale_${n - 2}', 'competition:scale_${n - 1}'},
      selectedCountry: 'CR',
      detectedCountry: 'CR',
      orderMode: custom
          ? CompetitionOrderMode.personalized
          : CompetitionOrderMode.automatic,
      orderPreference: CompetitionOrderPreference.globalFirst,
      pinnedCompetitionIds: ['scale_${n - 1}', 'scale_${n - 2}'],
    ).map((competition) => competition.id).toList();

/// A day with competitions of two countries, global ones and leftovers.
Snapshot _countrySnapshot({int segundaScore = 220}) {
  final base = _snapshot();
  final competitions = <Map<String, dynamic>>[
    {
      'id': 'cr_primera',
      'name': 'Primera de Costa Rica',
      'countryCode': 'CR',
      'relevanceScore': 660,
      'domesticTier': 1,
      'isPrimaryDomestic': true,
    },
    {
      'id': 'cr_segunda',
      'name': 'Segunda de Costa Rica',
      'countryCode': 'CR',
      'relevanceScore': segundaScore,
      'domesticTier': 2,
    },
    {
      'id': 'premier',
      'name': 'Premier League',
      'countryCode': 'GB-ENG',
      'relevanceScore': 980,
      'domesticTier': 1,
      'isPrimaryDomestic': true,
      'isGlobalRelevant': true,
    },
    {
      'id': 'championship',
      'name': 'Championship',
      'countryCode': 'GB-ENG',
      'relevanceScore': 400,
      'domesticTier': 2,
    },
    {
      'id': 'laliga',
      'name': 'LaLiga',
      'countryCode': 'ES',
      'relevanceScore': 920,
      'isGlobalRelevant': true,
      'domesticTier': 1,
      'isPrimaryDomestic': true,
    },
    {
      'id': 'ucl',
      'name': 'Champions League',
      'countryCode': 'EUROPE',
      'relevanceScore': 970,
      'isGlobalRelevant': true,
    },
    {
      'id': 'other',
      'name': 'Otra liga',
      'countryCode': 'XX',
      'relevanceScore': 300,
    },
  ];
  return Snapshot({
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': base.updatedAt.toIso8601String(),
    'competitions': competitions,
    'teams': [
      for (final c in competitions) ...[
        {'id': 'home_${c['id']}', 'name': 'Local ${c['name']}'},
        {'id': 'away_${c['id']}', 'name': 'Visita ${c['name']}'},
      ],
    ],
    'players': <dynamic>[],
    'matches': [
      for (final c in competitions)
        {
          ...base.matches.first.json,
          'id': 'match_${c['id']}',
          'competitionId': c['id'],
          'homeTeamId': 'home_${c['id']}',
          'awayTeamId': 'away_${c['id']}',
        },
    ],
    'standings': <dynamic>[],
  });
}

int _readsFor(int competitionCount) {
  final counter = _ReadCounter();
  final data = _scaleSnapshot(competitionCount, counter: counter);
  counter.reads = 0; // exclude Snapshot construction/indexing
  _order(data, custom: true, n: competitionCount);
  return counter.reads;
}

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
      // A followed league only orders first: never its own block, never
      // "Favoritos".
      expect(find.text('FAVORITOS'), findsNothing);
      expect(find.text('TUS COMPETICIONES'), findsNothing);
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

  test('the user country promotes only its primary domestic competition; '
      'stale pins never reorder', () {
    final data = _snapshot();
    // No country: editorial relevance only.
    expect(_ids(data, selected: null, detected: null), [
      'fb_comp_laliga',
      'fb_comp_cr',
    ]);
    // Costa Rica selected (it wins over the detected country): its primary
    // domestic competition goes before the big global ones.
    expect(_ids(data, selected: 'CR', detected: 'MX'), [
      'fb_comp_cr',
      'fb_comp_laliga',
    ]);
    // Another country: Liga Promerica is just "the rest" again.
    expect(_ids(data, selected: 'MX', detected: 'CR'), [
      'fb_comp_laliga',
      'fb_comp_cr',
    ]);
    // A pin that is no longer followed never reorders, in either mode.
    expect(_ids(data, detected: null, pinned: ['fb_comp_cr']), [
      'fb_comp_laliga',
      'fb_comp_cr',
    ]);
    expect(
      _ids(
        data,
        detected: null,
        pinned: ['fb_comp_cr'],
        mode: CompetitionOrderMode.personalized,
      ),
      ['fb_comp_laliga', 'fb_comp_cr'],
    );
    expect(
      _ids(
        data,
        detected: null,
        pinned: ['fb_comp_cr'],
        follows: {'competition:fb_comp_cr'},
      ),
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
      // pinned (own order) > primary of the country (CR) > global >
      // secondary of the country > rest.
      ['favorite', 'pinned', 'primary', 'global', 'secondary', 'rest'],
    );
    final unknown = data.competitions.firstWhere((item) => item.id == 'rest');
    expect(unknown.json.containsKey('countryCode'), isTrue);
    expect(unknown.json['countryCode'], isNull);
    expect(unknown.json.containsKey('domesticTier'), isTrue);
    expect(unknown.json['domesticTier'], isNull);
  });

  test('120 competitions and 1200 matches retain every group across ordering modes', () {
    final data = _scaleSnapshot(120);
    final allCompetitionIds = {for (final c in data.competitions) c.id};
    final allMatchIds = {for (final m in data.matches) m.id};
    expect(data.matches, hasLength(1200));

    for (final country in ['CR', 'JP']) {
      for (final custom in [false, true]) {
        final ids = orderMatchCompetitions(
          data: data,
          matches: data.matches,
          follows: const {'competition:scale_118', 'competition:scale_119'},
          selectedCountry: country,
          orderMode: custom
              ? CompetitionOrderMode.personalized
              : CompetitionOrderMode.automatic,
          orderPreference: CompetitionOrderPreference.globalFirst,
          pinnedCompetitionIds: const ['scale_119', 'scale_118'],
        ).map((c) => c.id).toList();

        // scale_i: i%6==0 primary CR, 1 primary JP, 2 global, 3 secondary CR,
        // 4 secondary JP, 5 other (ES); relevance falls with i.
        final own = country == 'CR' ? 0 : 1;
        List<String> group(bool Function(int kind) test) => [
          for (var i = 0; i < 118; i++)
            if (test(i % 6)) 'scale_$i',
        ];
        final primary = group((kind) => kind == own);
        final global = group((kind) => kind == 2);
        expect(ids, [
          if (custom) ...[
            'scale_119',
            'scale_118',
          ] else ...[
            'scale_118',
            'scale_119',
          ],
          // The legacy "global first" value passed here is not applied.
          ...primary,
          ...global,
          ...group((kind) => kind == own + 3),
          ...group((kind) => kind != own && kind != 2 && kind != own + 3),
        ]);
        // O(n) set checks; `expect(set, set)` in package:matcher is O(n^2).
        final idSet = ids.toSet();
        expect(idSet.length, ids.length, reason: 'no duplicate competitions');
        expect(idSet.containsAll(allCompetitionIds), isTrue);
        final displayed = {
          for (final m in data.matches)
            if (idSet.contains(m.competitionId)) m.id,
        };
        expect(displayed.length, allMatchIds.length);
        expect(displayed.containsAll(allMatchIds), isTrue);
      }
    }
  });

  test('competition ordering work grows ~n log n, not quadratically', () {
    final small = _readsFor(120); // 1200 matches
    final large = _readsFor(960); // 9600 matches (8x)
    // Deterministic: same input -> same reads on every machine.
    // n log n at 8x ≈ 8 * log(960)/log(120) ≈ 11.5x; quadratic would be 64x.
    // One extra pass over matches per competition would be ~8x * 120 = huge.
    printOnFailure('reads: 120 -> $small, 960 -> $large');
    expect(large / small, lessThan(24));
    // Absolute ceiling at the product size catches "re-scan every match per
    // competition" (≈ 120 * 1200 = 144k reads) even if it scales linearly.
    expect(small, lessThan(20000));
  });

  test('ordering 1200 matches stays fast (warm median, generous guard)', () {
    final data = _scaleSnapshot(120);
    for (var i = 0; i < 10; i++) {
      _order(data, custom: i.isOdd, n: 120); // JIT warm-up
    }
    final samples = <int>[];
    final sw = Stopwatch();
    for (var i = 0; i < 21; i++) {
      sw
        ..reset()
        ..start();
      _order(data, custom: i.isOdd, n: 120);
      sw.stop();
      samples.add(sw.elapsedMicroseconds);
    }
    samples.sort();
    final median = samples[samples.length ~/ 2];
    printOnFailure('median ${median}us, samples $samples');
    // Local median ≈ 0.3 ms; 50 ms is ~150x headroom for slow/shared CI
    // runners yet still fails on a real algorithmic blow-up.
    expect(median, lessThan(50000));
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
    // The highest score of the day is neither global nor domestic: it ranks
    // inside "the rest", below the country's primary and the global ones.
    expect(_ids(data, selected: 'CR'), [
      'fb_comp_cr',
      'fb_comp_laliga',
      'friendly',
    ]);
    expect(_ids(data, selected: null, detected: null), [
      'fb_comp_laliga',
      'friendly',
      'fb_comp_cr',
    ]);
  });

  test('without follows every competition stays visible', () {
    final data = _snapshot();
    expect(_ids(data, detected: null), ['fb_comp_laliga', 'fb_comp_cr']);
    expect(_ids(data, detected: 'CR'), ['fb_comp_cr', 'fb_comp_laliga']);
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

  test('a followed / pinned league keeps its priority over the primary of the '
      'country', () {
    final data = _snapshot();
    // Costa Rica selected, LaLiga followed: LaLiga first, then Liga Promerica.
    expect(
      _ids(data, selected: 'CR', follows: {'competition:fb_comp_laliga'}),
      ['fb_comp_laliga', 'fb_comp_cr'],
    );
    expect(
      _ids(
        data,
        selected: 'CR',
        follows: {'competition:fb_comp_laliga'},
        mode: CompetitionOrderMode.personalized,
        pinned: ['fb_comp_laliga'],
      ),
      ['fb_comp_laliga', 'fb_comp_cr'],
    );
  });

  test('following a team never promotes its whole competition', () {
    final data = _snapshot(includeCup: true);
    // The cup of the followed team is not promoted: it stays with the other
    // global competitions, ordered by relevance.
    expect(_ids(data, detected: null, follows: {'team:fb_team_lda'}), [
      'fb_comp_laliga',
      'fb_comp_cac',
      'fb_comp_cr',
    ]);
    expect(_ids(data, detected: 'CR', follows: {'team:fb_team_lda'}), [
      'fb_comp_cr',
      'fb_comp_laliga',
      'fb_comp_cac',
    ]);
  });

  test('Costa Rica selected: its primary competition after favourites / '
      'pinned and before the big global ones', () {
    final data = _countrySnapshot();
    expect(_ids(data, selected: 'CR', detected: null), [
      'cr_primera', // primary of Costa Rica
      'premier', 'ucl', 'laliga', // global, by relevance
      'cr_segunda', // secondary of Costa Rica
      'championship', 'other', // the rest, by relevance
    ]);
    // Followed and pinned competitions stay above the national primary.
    expect(
      _ids(
        data,
        selected: 'CR',
        detected: null,
        follows: {'competition:other', 'competition:laliga'},
        mode: CompetitionOrderMode.personalized,
        pinned: ['other'],
      ),
      [
        'other', // pinned
        'laliga', // followed
        'cr_primera',
        'premier',
        'ucl',
        'cr_segunda',
        'championship',
      ],
    );
  });

  test('England selected: the Premier League takes the primary national '
      'position', () {
    final data = _countrySnapshot();
    const expected = [
      'premier', // primary of England
      'ucl', 'laliga', // global
      'championship', // secondary of England
      'cr_primera', 'other', 'cr_segunda', // the rest, by relevance
    ];
    expect(_ids(data, selected: 'GB-ENG', detected: null), expected);
    // A United Kingdom selection covers its home nations.
    expect(_ids(data, selected: 'GB', detected: 'CR'), expected);
  });

  test('a secondary national competition stays below the big global ones, '
      'whatever its score', () {
    final data = _countrySnapshot(segundaScore: 999);
    final ids = _ids(data, selected: 'CR', detected: null);
    expect(ids.indexOf('cr_segunda'), greaterThan(ids.indexOf('premier')));
    expect(ids.indexOf('cr_segunda'), greaterThan(ids.indexOf('ucl')));
    expect(ids.indexOf('cr_segunda'), greaterThan(ids.indexOf('laliga')));
    expect(ids.indexOf('cr_segunda'), lessThan(ids.indexOf('championship')));
    expect(ids.first, 'cr_primera');
  });

  test('switching CR <-> England <-> Spain reorders the same matches: none '
      'lost, none duplicated', () {
    final data = _countrySnapshot();
    final allCompetitions = {for (final c in data.competitions) c.id};
    final allMatches = {for (final m in data.matches) m.id};
    final cr = _ids(data, selected: 'CR', detected: null);
    final england = _ids(data, selected: 'GB-ENG', detected: null);
    final spain = _ids(data, selected: 'ES', detected: null);
    expect(cr, isNot(england), reason: 'the country reorders');
    expect(spain, isNot(england));
    expect(spain, isNot(cr));
    // Each country puts its own primary competition first.
    expect(
      [cr.first, england.first, spain.first],
      ['cr_primera', 'premier', 'laliga'],
    );
    for (final ids in [cr, england, spain]) {
      expect(ids.toSet(), allCompetitions);
      expect(ids.length, allCompetitions.length, reason: 'no duplicates');
      expect({
        for (final m in data.matches)
          if (ids.contains(m.competitionId)) m.id,
      }, allMatches);
    }
    // Back to Costa Rica: exactly the first order again.
    expect(_ids(data, selected: 'CR', detected: null), cr);
    expect(data.matches, hasLength(allMatches.length));
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

      expect(find.text('FAVORITOS'), findsOneWidget);
      expect(find.text('TUS COMPETICIONES'), findsNothing);
      // Competitions follow "Favoritos" directly (no extra heading).
      expect(find.text('TODOS LOS PARTIDOS'), findsNothing);
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

    // Horizontal fling: left = next day, right = previous day. The strip
    // shows selected-1..selected+1, so visible dates reveal the selection.
    final swipe = find.byKey(const ValueKey('matches-date-swipe'));
    DateTime day(int offset) => today.add(Duration(days: offset));
    await tester.fling(swipe, const Offset(-300, 0), 1200);
    await tester.pumpAndSettle();
    expect(find.text(compact(day(3))), findsOneWidget);
    expect(find.text(compact(today)), findsNothing);
    for (var i = 0; i < 2; i++) {
      await tester.fling(swipe, const Offset(300, 0), 1200);
      await tester.pumpAndSettle();
    }
    expect(find.text(compact(day(-1))), findsOneWidget);
    // A slow horizontal drag is not a day change.
    await tester.timedDrag(
      swipe,
      const Offset(-60, 0),
      const Duration(seconds: 1),
    );
    await tester.pumpAndSettle();
    expect(find.text(compact(day(-1))), findsOneWidget);
    expect(find.text(compact(day(2))), findsNothing);
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

    // The followed league is ordered first, without a block of its own.
    expect(find.text('TUS COMPETICIONES'), findsNothing);
    expect(find.text('TODOS LOS PARTIDOS'), findsNothing);
    expect(find.text('FAVORITOS'), findsNothing);
    expect(find.text('Liga Promerica'), findsOneWidget);
    expect(find.text('LaLiga'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Liga Promerica')).dy,
      lessThan(tester.getTopLeft(find.text('LaLiga')).dy),
    );
    expect(tester.takeException(), isNull);
  });
}

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
        'relevanceScore': 660,
      },
      {
        'id': 'fb_comp_laliga',
        'name': 'LaLiga',
        'country': 'Spain',
        'relevanceScore': 920,
      },
      if (includeCup)
        {
          'id': 'fb_comp_cac',
          'name': 'CONCACAF Central American Cup',
          'country': 'CONCACAF',
          'relevanceScore': 700,
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
  Set<String> temporary = const {},
  String? selected,
  String? detected = 'CR',
}) => orderMatchCompetitions(
  data: data,
  matches: data.matches,
  follows: follows,
  temporaryInterests: temporary,
  selectedCountry: selected,
  detectedCountry: detected,
).map((competition) => competition.id).toList();

void main() {
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

  test('country preference is a ranking signal without hiding the catalog', () {
    expect(_ids(_snapshot(), selected: 'ES'), ['fb_comp_laliga', 'fb_comp_cr']);
    expect(_ids(_snapshot(), detected: 'CR'), ['fb_comp_laliga', 'fb_comp_cr']);
    expect(_ids(_snapshot(), selected: 'CR'), ['fb_comp_cr', 'fb_comp_laliga']);
  });

  test('switching selected countries reorders but preserves every match', () {
    final data = _snapshot();
    final before = data.matches.map((match) => match.id).toSet();

    expect(_ids(data, selected: 'CR'), ['fb_comp_cr', 'fb_comp_laliga']);
    expect(_ids(data, selected: 'ES'), ['fb_comp_laliga', 'fb_comp_cr']);
    expect(data.matches.map((match) => match.id).toSet(), before);
  });

  test(
    'temporary competition interest can be promoted without hiding others',
    () {
      expect(_ids(_snapshot(), temporary: {'competition:fb_comp_cr'}), [
        'fb_comp_cr',
        'fb_comp_laliga',
      ]);
    },
  );

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

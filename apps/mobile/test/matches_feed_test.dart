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
}

Snapshot _snapshot({
  bool costaRicaMatch = true,
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
      {'id': 'fb_comp_cr', 'name': 'Liga Promerica', 'country': 'Costa Rica'},
      {'id': 'fb_comp_laliga', 'name': 'LaLiga', 'country': 'Spain'},
    ],
    'teams': [
      {'id': 'fb_team_sap', 'name': 'Saprissa', 'country': 'Costa Rica'},
      {'id': 'fb_team_lda', 'name': 'Alajuelense', 'country': 'Costa Rica'},
      {'id': 'fb_team_betis', 'name': 'Real Betis', 'country': 'Spain'},
      {'id': 'fb_team_getafe', 'name': 'Getafe', 'country': 'Spain'},
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
  test('detected country orders Costa Rica first without hiding LaLiga', () {
    final data = _snapshot();
    expect(_ids(data), ['fb_comp_cr', 'fb_comp_laliga']);
    expect(data.matches.any((match) => match.id == 'fb_match_es'), isTrue);
  });

  test('LaLiga remains visible when Costa Rica has no games', () {
    final data = _snapshot(costaRicaMatch: false);
    expect(_ids(data), ['fb_comp_laliga']);
  });

  test('an international favorite has the highest priority', () {
    expect(_ids(_snapshot(), follows: {'competition:fb_comp_laliga'}), [
      'fb_comp_laliga',
      'fb_comp_cr',
    ]);
  });

  test('selected country changes order without hiding detected country', () {
    expect(_ids(_snapshot(), selected: 'ES'), ['fb_comp_laliga', 'fb_comp_cr']);
  });

  test('temporary interest orders remaining competitions', () {
    expect(
      _ids(_snapshot(), detected: null, temporary: {'team:fb_team_getafe'}),
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

  testWidgets('Costa Rica detection still renders a real LaLiga match', (
    tester,
  ) async {
    final data = _snapshot();
    tester.view.physicalSize = const Size(390, 1200);
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

    expect(find.text('Liga Promerica'), findsOneWidget);
    expect(find.text('LaLiga'), findsOneWidget);
    expect(find.text('Real Betis'), findsOneWidget);
    expect(find.text('Getafe'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Liga Promerica')).dy,
      lessThan(tester.getTopLeft(find.text('LaLiga')).dy),
    );
    expect(tester.takeException(), isNull);
  });
}

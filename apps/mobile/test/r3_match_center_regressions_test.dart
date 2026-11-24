import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/entities/entity_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/matches/match_screen.dart';
import 'package:futbeat/features/entities/standings.dart';

Snapshot fixture(String status) => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-11-20T00:00:00Z',
  'teams': [
    {'id': 'fb_home', 'name': 'Local'},
    {'id': 'fb_away', 'name': 'Visitante'},
  ],
  'players': [],
  'competitions': [
    {'id': 'fb_comp', 'name': 'Liga'},
  ],
  'standings': [],
  'matches': [
    {
      'id': 'fb_match',
      'competitionId': 'fb_comp',
      'homeTeamId': 'fb_home',
      'awayTeamId': 'fb_away',
      'startTime': '2099-01-01T12:00:00Z',
      'status': status,
      'events': [],
      'statistics': [
        {'type': 'possession', 'home': 50, 'away': 50},
      ],
    },
  ],
});
void main() {
  test(
    'stable presentation guards reuse parsed data; changed guards rebuild',
    () {
      final data = fixture('SCHEDULED');
      expect(identical(data.withBlockedAliases({}), data), isTrue);
      final blocked = data.withBlockedAliases({'fb_player_alias'});
      expect(identical(blocked, data), isFalse);
      expect(blocked.blockedDisplayAliases, {'fb_player_alias'});
      expect(
        identical(blocked.withBlockedAliases({'fb_player_alias'}), blocked),
        isTrue,
      );
      expect(blocked.withBlockedAliases({}).blockedDisplayAliases, isEmpty);
    },
  );

  test(
    'kickoff parsing is reused until the provider changes its timestamp',
    () {
      final raw = {'startTime': '2026-11-20T18:00:00Z'};
      final match = FootballMatch(raw);
      final first = match.startTime;
      expect(identical(first, match.startTime), isTrue);
      expect(first.hour, 12);
      raw['startTime'] = '2026-11-21T00:30:00Z';
      expect(match.startTime.day, 20);
      expect(match.startTime.hour, 18);
      expect(match.startTime.minute, 30);
      expect(identical(first, match.startTime), isFalse);
    },
  );

  testWidgets(
    'lineup profile keeps exact known player and retry recovers canonical full profile',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio();
      var attempts = 0;
      final carried = PlayerProfileMatchContext(
        player: Entity({
          'id': 'fb_player_context',
          'name': 'Jugador del partido',
          'number': 9,
        }),
        observedAt: DateTime.utc(2026, 11, 20),
        team: Entity({'id': 'fb_historical_team', 'name': 'Equipo histórico'}),
        summary: playerMatchSummary({'rating': 7.8}, []),
        statSections: const [],
        events: const [],
      );
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          repositoryProvider.overrideWithValue(ApiRepository(dio, db)),
          followsProvider.overrideWith((ref) => Stream.value({})),
          entitySnapshotProvider.overrideWith((ref, request) {
            attempts++;
            if (attempts == 1) {
              return Stream<Snapshot>.error(
                DioException(
                  requestOptions: RequestOptions(path: '/v1/entity'),
                  response: Response(
                    requestOptions: RequestOptions(),
                    statusCode: 503,
                  ),
                ),
              );
            }
            return Stream.value(
              Snapshot({
                'schemaVersion': 1,
                'demo': false,
                'updatedAt': '2026-11-20T12:00:00Z',
                'teams': [
                  {'id': 'fb_current_team', 'name': 'Club actual'},
                ],
                'players': [
                  {
                    'id': 'fb_player_context',
                    'name': 'Jugador recuperado',
                    'teamId': 'fb_current_team',
                  },
                ],
                'competitions': [],
                'matches': [],
                'standings': [],
              }),
            );
          }),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        container.dispose();
        dio.close();
        await db.close();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: EntityScreen(
              type: 'player',
              id: 'fb_player_context',
              playerMatchContext: carried,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Jugador del partido'), findsWidgets);
      expect(find.text('Equipo por confirmar'), findsOneWidget);
      expect(find.text('Actualizar'), findsOneWidget);
      await tester.tap(find.text('Actualizar'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.text('Jugador recuperado'), findsWidgets);
      expect(find.text('Club actual'), findsWidgets);
      expect(find.text('No pudimos cargar este perfil'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  test('valid provider rating appears; absent and invalid values do not grant a rating', () {
    for (final value in [7.8, '7.8']) {
      expect(playerMatchSummary({'rating': value}, []).rating, 7.8);
    }
    for (final value in [
      null,
      0,
      -1,
      11,
      'unavailable',
      double.nan,
      double.infinity,
    ]) {
      expect(playerMatchSummary({'rating': value}, []).rating, isNull);
    }
  });
  test('pre-match does not show placeholder comparisons; live data stays available', () {
    expect(
      matchStatisticsForDisplay(fixture('SCHEDULED').matches.single, null),
      isEmpty,
    );
    expect(
      matchStatisticsForDisplay(fixture('LIVE').matches.single, null),
      isNotEmpty,
    );
  });
  test(
    'provider Current token is presentation-only, genuine phase remains',
    () {
      expect(standingsDisplayLabel('Current'), 'Clasificación general');
      expect(standingsDisplayLabel('Apertura · Grupo A'), 'Apertura · Grupo A');
    },
  );
  testWidgets(
    'combined pitch explicitly distinguishes probable and confirmed without predicting players',
    (tester) async {
      final data = fixture('SCHEDULED');
      List<Json> xi(String side) => [
        for (var i = 1; i <= 11; i++)
          {
            'id': 'fb_player_${side}_$i',
            'name': 'Jugador $i',
            'number': i,
            'lineupPosition': i,
          },
      ];
      final detail = MatchDetail({
        'matchId': 'fb_match',
        'available': true,
        'home': {
          'lineupStatus': 'probable',
          'formation': '4-3-3',
          'starters': xi('h'),
          'substitutes': [],
        },
        'away': {
          'lineupStatus': 'confirmed',
          'formation': '4-3-3',
          'starters': xi('a'),
          'substitutes': [],
        },
        'incidents': [],
        'statistics': [],
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Lineups(data, data.matches.single, detail),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('lineup-status-Local')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('lineup-status-Visitante')),
        findsOneWidget,
      );
      expect(find.text('Alineación probable'), findsWidgets);
      expect(find.text('Alineación confirmada'), findsWidgets);
      expect(lineupPresentationState({}), LineupPresentationState.unknown);
      expect(tester.takeException(), isNull);
    },
  );
}

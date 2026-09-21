import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/matches/match_screen.dart';

void main() {
  test('formation rows map a 4-3-3 from attack to goalkeeper', () {
    final starters = [
      for (var i = 1; i <= 11; i++)
        <String, dynamic>{
          'name': 'Jugador $i',
          'number': i,
          'lineupPosition': i,
        },
    ];

    final rows = formationPlayerRows('4-3-3', starters);

    expect(rows, isNotNull);
    expect(rows!.map((row) => row.length).toList(), [3, 3, 4, 1]);
    expect(rows.first.first['name'], 'Jugador 9');
    expect(rows.last.single['name'], 'Jugador 1');
  });

  test('formation rows fall back when provider formation is incomplete', () {
    final starters = [
      for (var i = 1; i <= 10; i++)
        <String, dynamic>{'name': 'Jugador $i', 'lineupPosition': i},
    ];

    expect(formationPlayerRows('4-3-3', starters), isNull);
    expect(
      formationPlayerRows(null, [
        ...starters,
        {'name': '11'},
      ]),
      isNull,
    );
  });

  test(
    'adaptive formation keeps partial lineups visible by real positions',
    () {
      final rows = adaptiveFormationRows(null, [
        {'name': 'Goalkeeper', 'position': 'Goalkeeper', 'lineupPosition': 1},
        {'name': 'Defender', 'position': 'Defender', 'lineupPosition': 2},
        {'name': 'Midfielder', 'position': 'Midfielder', 'lineupPosition': 3},
        {'name': 'Forward', 'position': 'Forward', 'lineupPosition': 4},
      ]);

      expect(rows.map((row) => row.single['name']).toList(), [
        'Forward',
        'Midfielder',
        'Defender',
        'Goalkeeper',
      ]);
    },
  );

  test(
    'lineup player events use provider ids without matching invented names',
    () {
      final events = lineupEventsForPlayer(
        {'id': 'player-9', 'name': 'Jugador Nueve'},
        [
          {
            'type': 'GOAL',
            'playerId': 'player-9',
            'side': 'home',
            'minute': 63,
          },
          {
            'type': 'YELLOW_CARD',
            'playerId': 'other',
            'side': 'home',
            'minute': 70,
          },
          {
            'type': 'SUBSTITUTION',
            'outPlayerId': 'player-9',
            'team': 'home',
            'minute': 74,
          },
          {
            'type': 'GOAL',
            'playerId': 'player-9',
            'side': 'away',
            'minute': 80,
          },
        ],
        'home',
      );

      expect(events.map((event) => event.type).toList(), ['GOAL', 'SUB_OUT']);
      expect(events.map((event) => event.minute).toList(), [63, 74]);
    },
  );

  test('stat numeric parser accepts numbers and percentages safely', () {
    expect(statNumericValue(12), 12);
    expect(statNumericValue('54.5%'), 54.5);
    expect(statNumericValue('—'), isNull);
    expect(statNumericValue(null), isNull);
  });

  testWidgets('numeric match statistics render comparison bars', (
    tester,
  ) async {
    final match = FootballMatch({
      'id': 'fb_match_stats',
      'competitionId': 'fb_comp_stats',
      'homeTeamId': 'fb_team_home',
      'awayTeamId': 'fb_team_away',
      'startTime': '2026-09-19T00:00:00Z',
      'status': 'VERIFIED',
      'score': {'home': 2, 'away': 1},
      'events': <dynamic>[],
      'statistics': [
        {'label': 'Possession', 'home': '60', 'away': '40', 'unit': '%'},
        {'label': 'Shots', 'home': 12, 'away': 8},
      ],
      'provenance': {'source': 'test', 'receivedAt': '2026-09-19T02:00:00Z'},
    });

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: Statistics(match))),
    );

    expect(find.text('60%'), findsOneWidget);
    expect(find.text('40%'), findsOneWidget);
    expect(find.text('Possession'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'premium lineups fit a narrow phone with full and partial teams',
    (tester) async {
      tester.view.physicalSize = const Size(360, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final snapshot = Snapshot({
        'schemaVersion': 1,
        'demo': false,
        'updatedAt': '2026-09-20T12:00:00Z',
        'teams': [
          {'id': 'fb_home', 'name': 'Equipo Local', 'country': 'Costa Rica'},
          {
            'id': 'fb_away',
            'name': 'Equipo Visitante',
            'country': 'Costa Rica',
          },
        ],
        'players': <dynamic>[],
        'competitions': [
          {'id': 'fb_comp', 'name': 'Competición', 'country': 'Costa Rica'},
        ],
        'matches': [
          {
            'id': 'fb_match',
            'competitionId': 'fb_comp',
            'homeTeamId': 'fb_home',
            'awayTeamId': 'fb_away',
            'startTime': '2026-09-20T18:00:00Z',
            'status': 'VERIFIED',
            'score': {'home': 2, 'away': 1},
            'events': <dynamic>[],
            'statistics': <dynamic>[],
            'provenance': {
              'source': 'test',
              'receivedAt': '2026-09-20T20:00:00Z',
            },
          },
        ],
        'standings': <dynamic>[],
      });
      final detail = MatchDetail({
        'matchId': 'fb_match',
        'available': true,
        'pending': false,
        'detailLevel': 'full',
        'home': {
          'formation': '4-3-3',
          'starters': [
            for (var i = 1; i <= 11; i++)
              {
                'id': 'home-$i',
                'name': 'Nombre muy largo del jugador $i',
                'number': '$i',
                'lineupPosition': i,
                'rating': i == 9 ? 8.4 : null,
              },
          ],
          'substitutes': [
            {'id': 'home-12', 'name': 'Suplente Local', 'number': '12'},
          ],
          'coach': {'name': 'Entrenador Local'},
        },
        'away': {
          'formation': null,
          'starters': [
            {
              'id': 'away-1',
              'name': 'Portero Visitante',
              'position': 'Goalkeeper',
            },
            {
              'id': 'away-2',
              'name': 'Defensa Visitante',
              'position': 'Defender',
            },
            {
              'id': 'away-3',
              'name': 'Delantero Visitante',
              'position': 'Forward',
            },
          ],
          'substitutes': <dynamic>[],
        },
        'statistics': <dynamic>[],
        'incidents': [
          {'type': 'GOAL', 'playerId': 'home-9', 'side': 'home', 'minute': 63},
          {
            'type': 'SUBSTITUTION',
            'inPlayerId': 'home-12',
            'team': 'home',
            'minute': 71,
          },
        ],
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Lineups(snapshot, snapshot.matches.single, detail),
            ),
          ),
        ),
      );

      expect(find.text('Titulares'), findsNWidgets(2));
      expect(find.text('Suplentes'), findsOneWidget);
      expect(find.text('Entrenador Local'), findsOneWidget);
      expect(find.text('63′'), findsOneWidget);
      expect(find.text('71′'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

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
    'adaptive formation never invents a pitch without a declared formation',
    () {
      final rows = adaptiveFormationRows(null, [
        {'name': 'Goalkeeper', 'position': 'Goalkeeper', 'lineupPosition': 1},
        {'name': 'Defender', 'position': 'Defender', 'lineupPosition': 2},
        {'name': 'Midfielder', 'position': 'Midfielder', 'lineupPosition': 3},
        {'name': 'Forward', 'position': 'Forward', 'lineupPosition': 4},
      ]);

      expect(rows, isEmpty);
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

  test('player semantics announce only real lineup data', () {
    expect(
      lineupPlayerSemanticLabel(
        {
          'name': 'Juan Pérez',
          'shirtNumber': 10,
          'position': 'Forward',
          'captain': true,
          'rating': 7.8,
        },
        'titular',
        const [LineupPlayerEvent('GOAL', 63)],
      ),
      'Juan Pérez, dorsal 10, titular, Delantero, capitán, '
      'rating 7 punto 8, Gol minuto 63.',
    );
    expect(
      lineupPlayerSemanticLabel(
        {'name': 'Jugador Parcial'},
        'suplente',
        const [],
      ),
      'Jugador Parcial, suplente.',
    );
  });

  test('lineup status requires an explicit trusted signal', () {
    expect(lineupPresentationState(const {}), LineupPresentationState.unknown);
    expect(
      lineupPresentationState(const {
        'formation': '4-3-3',
        'starters': [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
      }),
      LineupPresentationState.unknown,
    );
    expect(
      lineupPresentationState(const {'lineupStatus': 'provisional'}),
      LineupPresentationState.provisional,
    );
    expect(
      lineupPresentationState(const {'lineupStatus': 'confirmed'}),
      LineupPresentationState.confirmed,
    );
  });

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
    expect(find.text('Posesión'), findsOneWidget);
    expect(find.text('Tiros'), findsOneWidget);
    expect(find.byKey(const ValueKey('stat-bars')), findsNWidgets(2));
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
          'coach': {'name': 'Entrenador Local', 'nationality': 'Costa Rica'},
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
      expect(find.text('Costa Rica'), findsOneWidget);
      expect(find.text('Portero Visitante'), findsOneWidget);
      expect(find.text('63′'), findsOneWidget);
      expect(find.text('71′'), findsOneWidget);
      expect(find.text('Alineación confirmada'), findsNothing);
      expect(tester.takeException(), isNull);

      // A provider may publish the bench/coach before its starters. Existing
      // partial data must stay visible instead of becoming an empty state
      // or an empty card for the other side.
      final benchOnly = MatchDetail({
        'matchId': 'fb_match',
        'available': true,
        'pending': false,
        'detailLevel': 'partial',
        'home': {
          'starters': <dynamic>[],
          'substitutes': [
            {'id': 'home-12', 'name': 'Suplente Local', 'number': '12'},
          ],
          'coach': {'name': 'Entrenador Local'},
        },
        'away': {'starters': <dynamic>[], 'substitutes': <dynamic>[]},
        'statistics': <dynamic>[],
        'incidents': <dynamic>[],
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Lineups(snapshot, snapshot.matches.single, benchOnly),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Titulares'), findsNothing);
      expect(find.text('Suplentes'), findsOneWidget);
      expect(find.text('Suplente Local'), findsOneWidget);
      expect(find.text('Entrenador Local'), findsOneWidget);
      expect(
        find.text('Todavía no hay alineaciones disponibles.'),
        findsNothing,
      );
      expect(find.text('Equipo Visitante'), findsNothing);
      expect(tester.takeException(), isNull);

      // Coaches without players remain useful partial information. Each side
      // stays separate and no confirmed lineup is inferred.
      final coachesOnly = MatchDetail({
        'matchId': 'fb_match',
        'available': true,
        'pending': false,
        'detailLevel': 'partial',
        'home': {
          'starters': <dynamic>[],
          'substitutes': <dynamic>[],
          'coach': {'name': 'Entrenador Local'},
        },
        'away': {
          'starters': <dynamic>[],
          'substitutes': <dynamic>[],
          'coach': {'name': 'Entrenador Visitante'},
        },
        'statistics': <dynamic>[],
        'incidents': <dynamic>[],
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Lineups(snapshot, snapshot.matches.single, coachesOnly),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Titulares no disponibles'), findsNWidgets(2));
      expect(find.text('Entrenador'), findsNWidgets(2));
      expect(find.text('Entrenador Local'), findsOneWidget);
      expect(find.text('Entrenador Visitante'), findsOneWidget);
      expect(find.text('Titulares'), findsNothing);
      expect(
        find.text('Todavía no hay alineaciones disponibles.'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);

      // One side with players, the other coach-only: useful partial data is
      // preserved without inventing a lineup status.
      final oneSide = MatchDetail({
        ...coachesOnly.json,
        'home': {
          'starters': <dynamic>[],
          'substitutes': [
            {'id': 'home-12', 'name': 'Suplente Local', 'number': '12'},
          ],
          'coach': {'name': 'Entrenador Local'},
        },
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Lineups(snapshot, snapshot.matches.single, oneSide),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Suplente Local'), findsOneWidget);
      expect(find.text('Titulares no disponibles'), findsOneWidget);
      expect(find.text('Entrenador Visitante'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // A formation without an XI is useful metadata, but never becomes a
      // fabricated pitch or a confirmed lineup.
      final formationOnly = MatchDetail({
        'matchId': 'fb_match',
        'available': true,
        'pending': false,
        'home': {
          'formation': '4-4-2',
          'starters': <dynamic>[],
          'substitutes': <dynamic>[],
        },
        'away': <String, dynamic>{},
        'statistics': <dynamic>[],
        'incidents': <dynamic>[],
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Lineups(snapshot, snapshot.matches.single, formationOnly),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('4-4-2'), findsOneWidget);
      expect(find.text('Titulares no disponibles'), findsOneWidget);
      expect(find.text('Alineación confirmada'), findsNothing);
    },
  );

  testWidgets(
    'overdue scheduled match stops pretending an empty lineup is loading',
    (tester) async {
      Snapshot snapshot(String startTime) => Snapshot({
        'schemaVersion': 1,
        'demo': false,
        'updatedAt': '2026-10-28T22:00:00Z',
        'teams': [
          {'id': 'fb_home', 'name': 'Equipo Local'},
          {'id': 'fb_away', 'name': 'Equipo Visitante'},
        ],
        'players': <dynamic>[],
        'competitions': [
          {'id': 'fb_comp', 'name': 'Competición'},
        ],
        'matches': [
          {
            'id': 'fb_match',
            'competitionId': 'fb_comp',
            'homeTeamId': 'fb_home',
            'awayTeamId': 'fb_away',
            'startTime': startTime,
            'status': 'SCHEDULED',
            'events': <dynamic>[],
            'statistics': <dynamic>[],
            'provenance': {
              'source': 'test',
              'receivedAt': '2026-10-28T22:00:00Z',
            },
          },
        ],
        'standings': <dynamic>[],
      });
      final detail = MatchDetail({
        'matchId': 'fb_match',
        'available': true,
        'pending': true,
        'detailLevel': 'full',
        'home': <String, dynamic>{},
        'away': <String, dynamic>{},
        'statistics': <dynamic>[],
        'incidents': <dynamic>[],
      });
      expect(detail.lineupPending, isTrue);

      final overdue = snapshot('2020-01-01T18:00:00Z');
      expect(overdue.matches.single.isAwaitingUpdate, isTrue);
      await tester.pumpWidget(
        MaterialApp(
          key: const ValueKey('overdue-lineup'),
          home: Scaffold(
            body: Lineups(overdue, overdue.matches.single, detail),
          ),
        ),
      );
      expect(find.text('Cargando alineaciones.'), findsNothing);
      expect(
        find.text('Todavía no hay alineaciones disponibles.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'combined pitch identifies both teams and adapts at large text scale',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final snapshot = Snapshot({
        'schemaVersion': 1,
        'demo': false,
        'updatedAt': '2026-10-27T12:00:00Z',
        'teams': [
          {
            'id': 'fb_home',
            'name': 'Asociación Deportiva Local de Nombre Extenso',
          },
          {
            'id': 'fb_away',
            'name': 'Club Deportivo Visitante de Nombre Extenso',
          },
        ],
        'players': <dynamic>[],
        'competitions': [
          {'id': 'fb_comp', 'name': 'Competición'},
        ],
        'matches': [
          {
            'id': 'fb_match',
            'competitionId': 'fb_comp',
            'homeTeamId': 'fb_home',
            'awayTeamId': 'fb_away',
            'startTime': '2026-10-27T18:00:00Z',
            'status': 'VERIFIED',
            'score': {'home': 0, 'away': 0},
            'events': <dynamic>[],
          },
        ],
        'standings': <dynamic>[],
      });
      List<Map<String, dynamic>> xi(String prefix) => [
        for (var i = 1; i <= 11; i++)
          {
            'id': '$prefix-$i',
            'canonicalId': '$prefix-$i',
            'name': 'Nombre muy largo del futbolista $i',
            'number': i,
            'lineupPosition': i,
            if (i == 1)
              'media': {
                'verificationStatus': 'VERIFIED',
                'url': 'https://media.example.test/$prefix-$i.png',
              },
          },
      ];
      final detail = MatchDetail({
        'matchId': 'fb_match',
        'available': true,
        'home': {
          'formation': '5-4-1',
          'starters': xi('home'),
          'substitutes': [
            {'id': 'home-12', 'name': 'Suplente local', 'number': 12},
            {'id': 'home-13', 'name': 'Segunda local', 'number': 13},
          ],
          'coach': {'name': 'Entrenadora Local'},
        },
        'away': {
          'formation': '4-2-3-1',
          'starters': xi('away'),
          'substitutes': [
            {'id': 'away-12', 'name': 'Suplente visitante', 'number': 12},
            {'id': 'away-13', 'name': 'Segundo visitante', 'number': 13},
          ],
          'coach': {'name': 'Entrenador Visitante'},
        },
        'incidents': <dynamic>[],
        'statistics': <dynamic>[],
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
      expect(find.byKey(const ValueKey('lineups-combined-pitch')), findsOne);
      expect(find.byKey(const ValueKey('lineup-home-suplente-grid')), findsOne);
      expect(find.byKey(const ValueKey('lineup-away-suplente-grid')), findsOne);
      expect(find.text('Local'), findsWidgets);
      expect(find.text('Visitante'), findsWidgets);
      expect(find.text('5-4-1'), findsWidgets);
      expect(find.text('4-2-3-1'), findsWidgets);
      expect(find.byKey(const ValueKey('lineup-Local-coach')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('lineup-Visitante-coach')),
        findsOneWidget,
      );

      final homeHalf = tester.getRect(
        find.byKey(const ValueKey('lineups-home-half')),
      );
      final awayHalf = tester.getRect(
        find.byKey(const ValueKey('lineups-away-half')),
      );
      final homeGoalkeeper = tester.getRect(
        find.byKey(const ValueKey('lineup-pitch-home-home-1')),
      );
      final homeForward = tester.getRect(
        find.byKey(const ValueKey('lineup-pitch-home-home-11')),
      );
      final awayForward = tester.getRect(
        find.byKey(const ValueKey('lineup-pitch-away-away-11')),
      );
      final awayGoalkeeper = tester.getRect(
        find.byKey(const ValueKey('lineup-pitch-away-away-1')),
      );
      expect(homeHalf.height, lineupPitchHalfHeight);
      expect(awayHalf.height, lineupPitchHalfHeight);
      expect(homeGoalkeeper.top, greaterThanOrEqualTo(homeHalf.top));
      expect(homeGoalkeeper.top, lessThan(homeForward.top));
      expect(
        homeGoalkeeper.bottom,
        lessThanOrEqualTo(homeHalf.top + 12 + lineupPenaltyAreaDepth),
      );
      expect(homeForward.bottom, lessThanOrEqualTo(homeHalf.bottom));
      expect(awayHalf.top, closeTo(homeHalf.bottom, .01));
      expect(awayForward.top, greaterThanOrEqualTo(awayHalf.top));
      expect(awayForward.top, lessThan(awayGoalkeeper.top));
      expect(
        awayGoalkeeper.top,
        greaterThanOrEqualTo(awayHalf.bottom - 12 - lineupPenaltyAreaDepth),
      );
      expect(awayGoalkeeper.bottom, lessThanOrEqualTo(awayHalf.bottom));
      expect(find.byKey(const ValueKey('lineup-photo-home-1')), findsOne);
      expect(
        find.byKey(const ValueKey('lineup-photo-fallback-home-2')),
        findsOne,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('lineup-photo-fallback-home-2')),
          matching: find.text('2'),
        ),
        findsNothing,
      );
      expect(find.byType(Image), findsNWidgets(2));
      for (final image in tester.widgetList<Image>(find.byType(Image))) {
        expect(image.errorBuilder, isNotNull);
        expect(
          image.errorBuilder!(
            tester.element(find.byType(Image).first),
            StateError('photo failed'),
            StackTrace.empty,
          ),
          isA<SizedBox>(),
        );
      }
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 1400),
              textScaler: TextScaler.linear(2),
            ),
            child: Scaffold(
              body: SingleChildScrollView(
                child: Lineups(snapshot, snapshot.matches.single, detail),
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('lineups-accessible-list')), findsOne);
      expect(find.byKey(const ValueKey('lineup-home-suplente-list')), findsOne);
      expect(
        find.byKey(const ValueKey('lineups-combined-pitch')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

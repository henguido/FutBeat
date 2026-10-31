import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/matches/match_screen.dart';

import 'support/visual_test_fonts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadFutBeatVisualFonts);

  testWidgets('Visual review: polished synthetic lineups', (tester) async {
    tester.view.physicalSize = const Size(390, 2320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    List<Map<String, dynamic>> players(String prefix) => [
      for (var i = 1; i <= 11; i++)
        {
          'id': '${prefix}_$i',
          'canonicalId': 'fb_player_${prefix}_$i',
          'name': i == 7 ? 'Futbolista de Nombre Extenso' : 'Jugador $i',
          'number': i,
          'lineupPosition': i,
          'position': i == 1
              ? 'G'
              : i < 6
              ? 'D'
              : i < 9
              ? 'M'
              : 'F',
          if (i == 9) 'rating': 8.1,
        },
    ];

    final snapshot = Snapshot({
      'schemaVersion': 1,
      'demo': false,
      'updatedAt': '2026-10-27T20:00:00Z',
      'teams': [
        {'id': 'fb_home', 'name': 'Equipo Local'},
        {'id': 'fb_away', 'name': 'Equipo Visitante'},
      ],
      'players': <dynamic>[],
      'competitions': [
        {'id': 'fb_comp', 'name': 'Competición de prueba'},
      ],
      'matches': [
        {
          'id': 'fb_match',
          'competitionId': 'fb_comp',
          'homeTeamId': 'fb_home',
          'awayTeamId': 'fb_away',
          'startTime': '2026-10-27T20:00:00Z',
          'status': 'VERIFIED',
          'score': {'home': 1, 'away': 2},
          'events': <dynamic>[],
        },
      ],
      'standings': <dynamic>[],
    });
    final detail = MatchDetail({
      'matchId': 'fb_match',
      'available': true,
      'home': {
        'formation': '4-3-3',
        'starters': players('home'),
        'substitutes': [
          for (var i = 12; i <= 17; i++)
            {
              'id': 'home_$i',
              'name': 'Suplente local $i',
              'number': i,
              'position': i.isEven ? 'D' : 'M',
            },
        ],
        'coach': {'name': 'Entrenadora Local'},
      },
      'away': {
        'formation': '4-2-3-1',
        'starters': players('away'),
        'substitutes': [
          for (var i = 12; i <= 17; i++)
            {
              'id': 'away_$i',
              'name': 'Suplente visitante $i',
              'number': i,
              'position': i.isEven ? 'F' : 'M',
            },
        ],
        'coach': {'name': 'Entrenador Visitante'},
      },
      'incidents': [
        {'type': 'GOAL', 'side': 'home', 'playerId': 'home_9', 'minute': 31},
        {
          'type': 'YELLOW_CARD',
          'side': 'away',
          'playerId': 'away_7',
          'minute': 56,
        },
      ],
      'statistics': <dynamic>[],
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: const Color(0xFF090D10),
          textTheme: ThemeData.dark().textTheme.apply(
            fontFamily: 'FutBeatRoboto',
          ),
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                const Text(
                  'DATOS SINTÉTICOS · RENDER LOCAL',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 8),
                Lineups(snapshot, snapshot.matches.single, detail),
              ],
            ),
          ),
        ),
      ),
    );

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/lineups_polish_synthetic.png'),
    );

    tester.view.physicalSize = const Size(390, 844);
    await tester.pump();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/lineups_polish_home_viewport.png'),
    );

    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -680),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/lineups_polish_away_viewport.png'),
    );
    expect(tester.takeException(), isNull);
  }, tags: 'golden');
}

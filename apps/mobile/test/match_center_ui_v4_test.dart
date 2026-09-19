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
        <String, dynamic>{
          'name': 'Jugador $i',
          'lineupPosition': i,
        },
    ];

    expect(formationPlayerRows('4-3-3', starters), isNull);
    expect(formationPlayerRows(null, [...starters, {'name': '11'}]), isNull);
  });

  test('stat numeric parser accepts numbers and percentages safely', () {
    expect(statNumericValue(12), 12);
    expect(statNumericValue('54.5%'), 54.5);
    expect(statNumericValue('—'), isNull);
    expect(statNumericValue(null), isNull);
  });

  testWidgets('numeric match statistics render comparison bars', (tester) async {
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
      'provenance': {
        'source': 'test',
        'receivedAt': '2026-09-19T02:00:00Z',
      },
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Statistics(match),
        ),
      ),
    );

    expect(find.text('60%'), findsOneWidget);
    expect(find.text('40%'), findsOneWidget);
    expect(find.text('Possession'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}

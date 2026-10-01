import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/matches/match_screen.dart';

FootballMatch _match({List<Map<String, dynamic>> statistics = const []}) =>
    FootballMatch({
      'id': 'fb_stats',
      'competitionId': 'fb_comp',
      'homeTeamId': 'fb_home',
      'awayTeamId': 'fb_away',
      'startTime': '2026-09-26T18:00:00Z',
      'status': 'VERIFIED',
      'score': {'home': 1, 'away': 0},
      'events': <dynamic>[],
      'statistics': statistics,
    });

MatchDetail _detail({
  List<Map<String, dynamic>> statistics = const [],
  bool pending = false,
}) => MatchDetail({
  'matchId': 'fb_stats',
  'available': true,
  'pending': pending,
  'statisticsState': pending ? 'pending' : 'available',
  'statistics': statistics,
  'home': <String, dynamic>{},
  'away': <String, dynamic>{},
  'incidents': <dynamic>[],
});

Future<void> _pump(
  WidgetTester tester, {
  required FootballMatch match,
  MatchDetail? detail,
  StatisticsDisplayMode mode = StatisticsDisplayMode.full,
  Size size = const Size(390, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: Statistics(match, detail: detail, mode: mode),
        ),
      ),
    ),
  );
}

Container _pill(WidgetTester tester, String key) => tester.widget<Container>(
  find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byType(Container),
  ),
);

void main() {
  const wideStats = <Map<String, dynamic>>[
    {'label': 'Fouls', 'home': 12, 'away': 9},
    {'label': 'Unknown Alpha', 'home': 1, 'away': 2},
    {'label': 'Shots on Goal', 'home': 5, 'away': 3},
    {'label': 'Pass accuracy', 'home': '88%', 'away': '81%'},
    {'label': 'Expected goals', 'home': 1.75, 'away': 0.8},
    {'label': 'Ball Possession', 'home': '55%', 'away': '45%'},
    {'label': 'Total Shots', 'home': 14, 'away': 8},
    {'label': 'Corner Kicks', 'home': 7, 'away': 2},
    {'label': 'Yellow Cards', 'home': 2, 'away': 4},
    {'label': 'Red Cards', 'home': 1, 'away': 0},
    {'label': 'Unknown Beta', 'home': 100, 'away': 100},
  ];

  test(
    'priority is deterministic, preserves input and unknown relative order',
    () {
      final original = wideStats
          .map((stat) => Map<String, dynamic>.from(stat))
          .toList();
      final ordered = orderedStatistics(wideStats);

      expect(ordered.map(statisticName), [
        'Ball Possession',
        'Expected goals',
        'Total Shots',
        'Shots on Goal',
        'Pass accuracy',
        'Corner Kicks',
        'Fouls',
        'Yellow Cards',
        'Red Cards',
        'Unknown Alpha',
        'Unknown Beta',
      ]);
      expect(wideStats, original);
    },
  );

  test('known translations and readable unknown labels are preserved', () {
    expect(statisticName({'type': 'Shots Total'}), 'Shots Total');
    expect(statisticHigherIsBetter('Shots Total'), isTrue);
    expect(statisticHigherIsBetter('Metric Nobody Knows'), isFalse);
  });

  test('discipline never opts into higher-is-better semantics', () {
    for (final name in ['Fouls', 'Yellow Cards', 'Red Cards', 'Faltas']) {
      expect(statisticHigherIsBetter(name), isFalse, reason: name);
    }
  });

  testWidgets('detail statistics take priority over match statistics', (
    tester,
  ) async {
    await _pump(
      tester,
      match: _match(
        statistics: const [
          {'label': 'Shots', 'home': 99, 'away': 98},
        ],
      ),
      detail: _detail(
        statistics: const [
          {'label': 'Ball Possession', 'home': '61%', 'away': '39%'},
        ],
      ),
    );
    expect(find.text('61%'), findsOneWidget);
    expect(find.text('99'), findsNothing);
  });

  testWidgets('empty detail falls back to match statistics', (tester) async {
    await _pump(
      tester,
      match: _match(
        statistics: const [
          {'label': 'Shots on Goal', 'home': 6, 'away': 2},
        ],
      ),
      detail: _detail(),
    );
    expect(find.text('Tiros a puerta'), findsOneWidget);
    expect(find.text('6'), findsOneWidget);
  });

  testWidgets('full mode groups every known row; a type FutBeat cannot '
      'name is hidden, never shown as a raw provider key', (tester) async {
    await _pump(tester, match: _match(statistics: wideStats));
    for (final group in [
      'Resumen',
      'Ataque',
      'Pases',
      'Defensa',
      'Disciplina',
    ]) {
      expect(find.text(group), findsOneWidget, reason: group);
    }
    expect(find.text('Goles esperados (xG)'), findsOneWidget);
    expect(find.text('Tiros totales'), findsOneWidget);
    // Only unknown rows would have filled "Otras estadísticas".
    expect(find.text('Otras estadísticas'), findsNothing);
    expect(find.text('Unknown Alpha'), findsNothing);
    expect(find.text('Unknown Beta'), findsNothing);
  });

  testWidgets('provider spellings of known types are translated', (
    tester,
  ) async {
    await _pump(
      tester,
      match: _match(
        statistics: const [
          {'label': 'Throw In', 'home': 21, 'away': 18},
          {'label': 'goal_kick', 'home': 7, 'away': 9},
          {'label': 'YellowCard', 'home': 2, 'away': 1},
          {'label': 'Corner', 'home': 4, 'away': 3},
          {'label': 'Shot On Goal', 'home': 5, 'away': 2},
          {'label': 'Free-Kicks', 'home': 11, 'away': 12},
        ],
      ),
    );
    for (final label in [
      'Saques de banda',
      'Saques de meta',
      'Tarjetas amarillas',
      'Córners',
      'Tiros a puerta',
      'Tiros libres',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    for (final raw in ['Throw In', 'goal_kick', 'YellowCard', 'Corner']) {
      expect(find.text(raw), findsNothing, reason: raw);
    }
  });

  testWidgets('key statistics skip data-less 0-0 rows, keep real zeros', (
    tester,
  ) async {
    await _pump(
      tester,
      match: _match(
        statistics: const [
          {'label': 'Throw In', 'home': 0, 'away': 0},
          {'label': 'Passes', 'home': 0, 'away': 0},
          {'label': 'Ball Possession', 'home': '50%', 'away': '50%'},
          {'label': 'Shots on Goal', 'home': 0, 'away': 0},
          {'label': 'Red Cards', 'home': 0, 'away': 0},
          {'label': 'Fouls', 'home': 9, 'away': 11},
        ],
      ),
      mode: StatisticsDisplayMode.compact,
    );
    expect(find.text('Saques de banda'), findsNothing);
    expect(find.text('Pases'), findsNothing);
    expect(find.text('Posesión'), findsOneWidget);
    expect(find.text('Tiros a puerta'), findsOneWidget);
    expect(find.text('Faltas'), findsOneWidget);
    expect(find.text('Tarjetas rojas'), findsOneWidget);
    // The full tab still lists every known row.
    await _pump(
      tester,
      match: _match(
        statistics: const [
          {'label': 'Throw In', 'home': 0, 'away': 0},
        ],
      ),
    );
    expect(find.text('Saques de banda'), findsOneWidget);
  });

  testWidgets('compact mode stays flat and limits the summary to four rows', (
    tester,
  ) async {
    await _pump(
      tester,
      match: _match(statistics: wideStats),
      mode: StatisticsDisplayMode.compact,
    );
    expect(find.byKey(const ValueKey('stat-bars')), findsNWidgets(4));
    expect(find.text('Resumen'), findsNothing);
    expect(find.text('Precisión de pases'), findsNothing);
  });

  testWidgets('normal metrics emphasize home, away, and neither on ties', (
    tester,
  ) async {
    await _pump(
      tester,
      match: _match(
        statistics: const [
          {'label': 'Shots', 'home': 12, 'away': 8},
          {'label': 'Expected goals', 'home': 0.5, 'away': 1.25},
          {'label': 'Corner Kicks', 'home': 3, 'away': 3},
        ],
      ),
    );
    expect(
      (_pill(tester, 'stat-shots-home').decoration as BoxDecoration).color,
      isNot(Colors.transparent),
    );
    expect(
      (_pill(tester, 'stat-shots-away').decoration as BoxDecoration).color,
      Colors.transparent,
    );
    expect(
      (_pill(tester, 'stat-expected goals-away').decoration as BoxDecoration)
          .color,
      isNot(Colors.transparent),
    );
    expect(
      (_pill(tester, 'stat-corner kicks-home').decoration as BoxDecoration)
          .color,
      Colors.transparent,
    );
    expect(
      (_pill(tester, 'stat-corner kicks-away').decoration as BoxDecoration)
          .color,
      Colors.transparent,
    );
  });

  testWidgets('fouls, yellow cards and red cards never look like wins', (
    tester,
  ) async {
    await _pump(
      tester,
      match: _match(
        statistics: const [
          {'label': 'Fouls', 'home': 12, 'away': 8},
          {'label': 'Yellow Cards', 'home': 1, 'away': 4},
          {'label': 'Red Cards', 'home': 2, 'away': 0},
        ],
      ),
    );
    for (final key in [
      'stat-fouls-home',
      'stat-yellow cards-away',
      'stat-red cards-home',
    ]) {
      expect(
        (_pill(tester, key).decoration as BoxDecoration).color,
        Colors.transparent,
        reason: key,
      );
    }
  });

  testWidgets('bars handle zeroes, percentages, decimals and missing sides', (
    tester,
  ) async {
    await _pump(
      tester,
      match: _match(
        statistics: const [
          {'label': 'Shots', 'home': 0, 'away': 0},
          {'label': 'Possession', 'home': 0, 'away': '100%', 'unit': '%'},
          {'label': 'Expected goals', 'home': 1.25, 'away': 0.75},
          {'label': 'Passes', 'home': '—', 'away': 420},
          {'label': 'Corners', 'home': null, 'away': 6},
        ],
      ),
    );
    expect(find.byKey(const ValueKey('stat-bars')), findsNWidgets(3));
    expect(find.text('100%'), findsOneWidget);
    expect(find.text('100%%'), findsNothing);
    expect(find.text('1.25'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending and settled empty states remain calm', (tester) async {
    await _pump(tester, match: _match(), detail: _detail(pending: true));
    expect(find.bySemanticsLabel('Cargando estadísticas…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await _pump(tester, match: _match(), detail: _detail());
    expect(find.text('Sin estadísticas'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('statistics arriving later replace the in-place pending state', (
    tester,
  ) async {
    await _pump(tester, match: _match(), detail: _detail(pending: true));
    await _pump(
      tester,
      match: _match(),
      detail: _detail(
        statistics: const [
          {'label': 'Ball Possession', 'home': 52, 'away': 48, 'unit': '%'},
        ],
      ),
    );
    expect(find.text('Cargando estadísticas…'), findsNothing);
    expect(find.text('52%'), findsOneWidget);
  });

  for (final width in [320.0, 360.0, 390.0, 430.0]) {
    testWidgets('$width px fits long labels, large values and many rows', (
      tester,
    ) async {
      await _pump(
        tester,
        match: _match(
          statistics: [
            ...wideStats,
            const {
              'label':
                  'Provider metric with an exceptionally long readable label',
              'home': 123456,
              'away': 98765.43,
            },
          ],
        ),
        size: Size(width, 1400),
      );
      expect(find.byType(Statistics), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

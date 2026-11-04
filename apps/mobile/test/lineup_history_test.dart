import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/features/matches/lineup_history.dart';
import 'package:futbeat/features/matches/lineup_history_section.dart';

const _alex = LineupHistoryPlayer(id: 'p1', name: 'Alex Titular');
const _bea = LineupHistoryPlayer(id: 'p2', name: 'Beatriz Central');
const _carla = LineupHistoryPlayer(id: 'p3', name: 'Carla Suplente');

LineupHistoryEntry entry(
  int index, {
  String? formation = '4-3-3',
  List<LineupHistoryPlayer> starters = const [_alex, _bea],
  List<LineupHistoryPlayer> bench = const [_carla],
  String? coach = 'Entrenador Real',
  String? captain = 'p1',
  List<LineupHistorySubstitution> substitutions = const [],
  LineupStatus status = LineupStatus.unknown,
}) => LineupHistoryEntry(
  matchId: 'm$index',
  teamId: 'team',
  kickoff: DateTime.utc(2026, 9, 20 - index),
  competition: 'Liga de Prueba',
  opponent: LineupHistoryTeam(
    id: 'o$index',
    name: 'Rival con nombre suficientemente largo número $index',
  ),
  homeAway: index.isEven ? LineupHomeAway.home : LineupHomeAway.away,
  result: '2-1',
  formation: formation,
  starters: starters,
  bench: bench,
  coach: coach,
  captainPlayerId: captain,
  substitutions: substitutions,
  lineupStatus: status,
);

class _Adapter implements LineupHistoryAdapter<int> {
  @override
  List<LineupHistoryEntry> normalize(Iterable<int> source) => [
    for (final value in source) entry(value),
  ];
}

Future<void> pump(
  WidgetTester tester,
  List<LineupHistoryEntry> entries, {
  double width = 390,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: LineupHistorySection(
            teamName: 'Equipo con nombre extraordinariamente largo',
            entries: entries,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('adapter normalizes local input without transport concerns', () {
    final result = _Adapter().normalize([1, 2, 3]);
    expect(result.map((item) => item.matchId), ['m1', 'm2', 'm3']);
  });

  test('lineupStatus defaults to unknown', () {
    expect(entry(1).lineupStatus, LineupStatus.unknown);
  });

  test('summarizes formation, appearances, starts, coach and captain', () {
    final summary = LineupHistorySummarizer.summarize([
      entry(1),
      entry(2),
      entry(3, formation: '4-4-2', starters: const [_alex]),
    ]);
    expect(summary.mostUsedFormation, '4-3-3');
    final alex = summary.playerFrequencies.firstWhere(
      (item) => item.player.id == 'p1',
    );
    expect(alex.appearances, 3);
    expect(alex.starts, 3);
    expect(alex.startingPercentage, 100);
    final carla = summary.playerFrequencies.firstWhere(
      (item) => item.player.id == 'p3',
    );
    expect(carla.appearances, 3);
    expect(carla.starts, 0);
    expect(summary.latestCoach, 'Entrenador Real');
    expect(summary.frequentCaptain?.id, 'p1');
  });

  test('formation tie and incomplete evidence fail closed', () {
    final summary = LineupHistorySummarizer.summarize([
      entry(1, formation: '4-3-3'),
      entry(2, formation: '4-4-2'),
      entry(
        3,
        formation: null,
        starters: const [
          LineupHistoryPlayer(id: 'same', name: 'Duplicado'),
          LineupHistoryPlayer(id: 'same', name: 'Duplicado'),
          LineupHistoryPlayer(name: ''),
        ],
        bench: const [],
        coach: null,
        captain: null,
      ),
    ]);
    expect(summary.mostUsedFormation, isNull);
    expect(
      summary.playerFrequencies.where((item) => item.player.id == 'same'),
      hasLength(1),
    );
  });

  testWidgets('empty history renders nothing', (tester) async {
    await pump(tester, const []);
    expect(find.textContaining('Historial de alineaciones'), findsNothing);
  });

  testWidgets('shows three initially, expands and collapses five', (
    tester,
  ) async {
    await pump(tester, [for (var i = 1; i <= 5; i++) entry(i)]);
    expect(find.byType(ExpansionTile), findsNWidgets(3));
    await tester.tap(find.byKey(const ValueKey('lineup-history-more')));
    await tester.pumpAndSettle();
    expect(find.byType(ExpansionTile), findsNWidgets(5));
    expect(find.text('Ver menos'), findsOneWidget);
  });

  testWidgets('expanded detail shows coach, captain and substitutions', (
    tester,
  ) async {
    await pump(tester, [
      entry(
        1,
        substitutions: const [
          LineupHistorySubstitution(
            playerOut: _alex,
            playerIn: _carla,
            minute: 67,
          ),
        ],
      ),
    ]);
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    expect(find.text('Entrenador: Entrenador Real'), findsOneWidget);
    expect(find.text('Capitán: Alex Titular'), findsOneWidget);
    expect(find.text("Alex Titular → Carla Suplente · 67'"), findsOneWidget);
  });

  testWidgets('unknown never renders Confirmada; explicit evidence does', (
    tester,
  ) async {
    await pump(tester, [entry(1)]);
    expect(find.text('Confirmada'), findsNothing);
    await pump(tester, [entry(1, status: LineupStatus.confirmed)]);
    expect(find.text('Confirmada'), findsOneWidget);
  });

  for (final width in [320.0, 360.0, 390.0]) {
    testWidgets('${width.toInt()} px long names have no overflow', (
      tester,
    ) async {
      await pump(tester, [entry(1), entry(2), entry(3)], width: width);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(ExpansionTile).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}

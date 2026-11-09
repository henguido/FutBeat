import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/theme.dart';
import 'package:futbeat/features/matches/match_screen.dart';

import 'support/visual_test_fonts.dart';

const _id = 'fb_match_synthetic245';
const _home = 'fb_team_synthetic245_h';
const _away = 'fb_team_synthetic245_a';
const _competition = 'fb_comp_synthetic245';

Snapshot _snapshot(Object? score) => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-11-01T00:00:00Z',
  'competitions': [
    {'id': _competition, 'name': 'Competición sintética'},
  ],
  'teams': [
    {'id': _home, 'name': 'Local de Nombre Extraordinariamente Largo'},
    {'id': _away, 'name': 'Visitante de Nombre Extraordinariamente Largo'},
  ],
  'players': [],
  'matches': [
    {
      'id': _id,
      'competitionId': _competition,
      'homeTeamId': _home,
      'awayTeamId': _away,
      'startTime': '2026-10-31T18:00:00Z',
      'status': 'VERIFIED',
      'score': score,
      'events': [],
    },
  ],
  'standings': [],
});

Future<void> _pump(
  WidgetTester tester,
  Object? score, {
  double scale = 1,
}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final data = _snapshot(score);
  await tester.pumpWidget(
    MaterialApp(
      theme: futbeatTheme(),
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(360, 800),
          textScaler: TextScaler.linear(scale),
        ),
        child: Scaffold(
          body: SingleChildScrollView(
            child: MatchHero(
              data: data,
              match: data.match(_id)!,
              competition: data.competition(_competition)!,
              detail: MatchDetail.empty(_id),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFutBeatVisualFonts);

  final invalidScores = <Object?>[
    null,
    <String, dynamic>{},
    {'home': null, 'away': 1},
    {'home': 1, 'away': null},
    {'home': -1, 'away': 0},
    {'home': 1.5, 'away': 0},
    {'home': double.nan, 'away': 0},
    {'home': double.infinity, 'away': 0},
    {'home': '1', 'away': 0},
    'unavailable',
  ];
  for (var i = 0; i < invalidScores.length; i++) {
    testWidgets(
      'unknown or malformed score $i is not a spoken/painted result',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          await _pump(tester, invalidScores[i]);
          final hero = find.byKey(const ValueKey('match-hero'));
          expect(
            find.descendant(of: hero, matching: find.text('—')),
            findsOneWidget,
          );
          final label = tester.getSemantics(hero).label;
          expect(label, contains('Marcador no disponible'));
          expect(label, isNot(contains('null')));
          expect(label, isNot(contains('0, Visitante')));
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );
  }

  testWidgets('verified zero is a real score, never mistaken for missing', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await _pump(tester, {'home': 0, 'away': 0});
      expect(find.text('0 - 0'), findsOneWidget);
      final label = tester
          .getSemantics(find.byKey(const ValueKey('match-hero')))
          .label;
      expect(label, contains('Largo 0, Visitante'));
      expect(label, isNot(contains('Marcador no disponible')));
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('integral JSON numeric goals preserve their verified value', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await _pump(tester, {'home': 2.0, 'away': 0.0});
      expect(find.text('2 - 0'), findsOneWidget);
      final label = tester
          .getSemantics(find.byKey(const ValueKey('match-hero')))
          .label;
      expect(label, contains('Largo 2, Visitante'));
      expect(label, isNot(contains('Marcador no disponible')));
      expect(label, isNot(contains('2.0')));
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('font-backed narrow header accepts a valid score correction', (
    tester,
  ) async {
    await _pump(tester, {'home': 3, 'away': 1}, scale: 1.6);
    expect(find.text('3 - 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _pump(tester, {'home': 2, 'away': 1}, scale: 1.6);
    expect(find.text('2 - 1'), findsOneWidget);
    expect(find.text('3 - 1'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

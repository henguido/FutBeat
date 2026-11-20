import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/matches/match_screen.dart';

void main() {
  for (final state in ['unavailable', 'missing', 'error', 'pending']) {
    testWidgets('standings distinguishes $state', (tester) async {
      final data = Snapshot({
        'schemaVersion': 1,
        'updatedAt': '2026-10-31T18:00:00Z',
        'demo': false,
        'competitions': [],
        'teams': [],
        'players': [],
        'matches': [],
        'standings': [],
        'coverage': {'standings': state},
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MatchStandingsTab(
              data,
              'fb_comp_test',
              refreshing: state == 'pending',
            ),
          ),
        ),
      );
      expect(
        find.text(switch (state) {
          'unavailable' => 'Sin tabla disponible',
          'error' => 'No se pudo actualizar la tabla',
          'pending' => 'Cargando tabla…',
          _ => 'Tabla aún no descargada',
        }),
        findsOneWidget,
      );
    });
  }
}

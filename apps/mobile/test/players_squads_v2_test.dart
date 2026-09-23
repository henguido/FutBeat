import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/shared/widgets.dart';

void main() {
  testWidgets('squad player tile shows number position and country', (
    tester,
  ) async {
    final player = Entity({
      'id': 'fb_player_test',
      'name': 'Ana Gol',
      'country': 'Costa Rica',
      'position': 'Forward',
      'shirtNumber': 9,
      'aliases': <dynamic>[],
    });

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: EntityTile(player, 'player'))),
    );

    expect(find.text('Ana Gol'), findsOneWidget);
    expect(find.text('#9 · Delantero · Costa Rica'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('non-player entity tile keeps normal country subtitle', (
    tester,
  ) async {
    final team = Entity({
      'id': 'fb_team_test',
      'name': 'Equipo Test',
      'country': 'Costa Rica',
      'aliases': <dynamic>[],
    });

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: EntityTile(team, 'team'))),
    );

    expect(find.text('Costa Rica'), findsOneWidget);
    expect(find.textContaining('#'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

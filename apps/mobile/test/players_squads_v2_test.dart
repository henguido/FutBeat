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

  testWidgets('player profile facts show squad statistics', (tester) async {
    final player = Entity({
      'id': 'fb_player_profile',
      'name': 'Ana Gol',
      'country': 'Costa Rica',
      'position': 'Forwards',
      'shirtNumber': 9,
      'age': 24,
      'dateOfBirth': '2002-05-14',
      'matchesPlayed': 18,
      'goals': 7,
      'assists': 4,
      'rating': 7.4,
      'injured': true,
      'aliases': <dynamic>[],
    });

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: PlayerProfileFacts(player))),
    );

    expect(find.text('Delantero'), findsOneWidget);
    expect(find.text('Dorsal #9'), findsOneWidget);
    expect(find.text('24 años'), findsOneWidget);
    expect(find.text('18 PJ'), findsOneWidget);
    expect(find.text('7 goles'), findsOneWidget);
    expect(find.text('4 asist.'), findsOneWidget);
    expect(find.text('Rating 7.4'), findsOneWidget);
    expect(find.text('Lesionado'), findsOneWidget);
    expect(find.text('Nacimiento: 2002-05-14'), findsOneWidget);
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

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/entities/team_profile.dart';

// #160 (app slice): age, freshness and one row per canonical player.
// Synthetic players only.

Entity _player(
  String id, {
  String position = 'Defender',
  Object? number,
  Object? age,
  String? born,
}) => Entity({
  'id': id,
  'name': 'Jugador $id',
  'position': position,
  'shirtNumber': ?number,
  'age': ?age,
  'dateOfBirth': ?born,
  'nationality': 'Nowhere',
});

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('age from the birth date (before/after the birthday), else age', () {
    final now = DateTime(2026, 9, 29);
    expect(playerAge(_player('a', born: '2000-09-29'), now: now), 26);
    expect(playerAge(_player('b', born: '2000-09-30'), now: now), 25);
    expect(playerAge(_player('c', age: 31), now: now), 31);
    expect(playerAge(_player('d', age: 0), now: now), isNull);
    expect(playerAge(_player('e', born: 'not a date'), now: now), isNull);
    expect(playerAge(_player('f'), now: now), isNull);
    // Implausible birth date: the provider's age instead.
    expect(playerAge(_player('g', born: '2030-01-01', age: 22), now: now), 22);
  });

  test('a player listed twice appears once', () {
    final groups = squadGroups([
      _player('p1', number: 4),
      _player('p1', number: 4),
      _player('p2', number: 2),
    ]);
    expect(groups.single.$2.map((p) => p.id), ['p2', 'p1']);
  });

  testWidgets('rows show position, age and nationality', (tester) async {
    await _pump(
      tester,
      TeamSquad([
        _player('p1', number: 5, age: 27),
        _player('p2', position: 'Goalkeeper', number: 1),
      ], state: 'AVAILABLE'),
    );
    expect(find.text('Defensa · 27 años · Nowhere'), findsOneWidget);
    expect(find.text('Portero · Nowhere'), findsOneWidget);
    expect(find.text('2 jugadores'), findsOneWidget);
  });

  testWidgets('a STALE squad says since when; a fresh one says nothing', (
    tester,
  ) async {
    await _pump(
      tester,
      TeamSquad(
        [_player('p1')],
        state: 'STALE',
        updatedAt: DateTime.utc(2026, 9, 12, 18),
      ),
    );
    expect(find.text('1 jugador · Actualizada el 12 sep'), findsOneWidget);
    // Another year says so; a future date is never shown.
    await _pump(
      tester,
      TeamSquad(
        [_player('p1')],
        state: 'STALE',
        updatedAt: DateTime.utc(2025, 3, 3, 18),
      ),
    );
    expect(find.text('1 jugador · Actualizada el 3 mar 2025'), findsOneWidget);
    await _pump(
      tester,
      TeamSquad(
        [_player('p1')],
        state: 'STALE',
        updatedAt: DateTime.now().toUtc().add(const Duration(days: 30)),
      ),
    );
    expect(find.text('1 jugador · Pendiente de actualizar'), findsOneWidget);
    await _pump(tester, TeamSquad([_player('p1')], state: 'STALE'));
    expect(find.text('1 jugador · Pendiente de actualizar'), findsOneWidget);
    await _pump(tester, TeamSquad([_player('p1')], state: 'AVAILABLE'));
    expect(find.text('1 jugador'), findsOneWidget);
  });

  testWidgets('empty squad: pending vs not available stay distinct', (
    tester,
  ) async {
    await _pump(tester, const TeamSquad([], state: 'PENDING'));
    expect(find.text('Plantilla pendiente'), findsOneWidget);
    await _pump(tester, const TeamSquad([], state: 'CONFIRMED_EMPTY'));
    expect(find.text('Plantilla no disponible'), findsOneWidget);
  });

  test('shirt number: only a real dorsal, never 0 or garbage', () {
    expect(_player('a', number: 7).shirtNumber, 7);
    expect(_player('b', number: '23').shirtNumber, 23);
    expect(_player('c', number: 9.0).shirtNumber, 9);
    for (final unknown in <Object>[0, '0', '', '  ', 'n/a', -1, 7.5]) {
      expect(
        _player('x', number: unknown).shirtNumber,
        isNull,
        reason: '$unknown',
      );
    }
    expect(_player('y').shirtNumber, isNull);
    expect(shirtNumberOf(null), isNull);
  });

  testWidgets('squad rows never print a 0 dorsal', (tester) async {
    await _pump(
      tester,
      TeamSquad([
        _player('p1', number: 0),
        _player('p2', number: 8),
      ], state: 'AVAILABLE'),
    );
    expect(find.text('0'), findsNothing);
    expect(find.text('8'), findsOneWidget);
    expect(find.text('–'), findsOneWidget);
  });
}

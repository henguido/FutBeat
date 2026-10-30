import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/features/matches/live_field_card.dart';

void main() {
  testWidgets('illustrative LIVE field fits a narrow Android screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: LiveFieldCard(
            homeName: 'Club Deportivo de Nombre Largo',
            awayName: 'Otro Club de Nombre Largo',
            score: '2 : 1',
            status: "78′ · En vivo",
            latestEvent: "64′ · Gol · Jugador de prueba",
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('live-field-card')), findsOneWidget);
    expect(find.text('2 : 1'), findsOneWidget);
    expect(find.text('Vista ilustrativa'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

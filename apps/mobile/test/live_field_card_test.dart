import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
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
      MaterialApp(
        home: Scaffold(
          body: LiveFieldCard(
            home: Entity({
              'id': 'home',
              'name': 'Club Deportivo de Nombre Largo',
            }),
            away: Entity({'id': 'away', 'name': 'Otro Club de Nombre Largo'}),
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

  testWidgets('LIVE pulse stops when reduced motion is requested', (
    tester,
  ) async {
    final home = Entity({'id': 'home', 'name': 'Local'});
    final away = Entity({'id': 'away', 'name': 'Visitante'});
    Widget screen(bool reduceMotion) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(
          body: LiveFieldCard(
            home: home,
            away: away,
            score: '1 : 0',
            status: 'En vivo',
          ),
        ),
      ),
    );
    await tester.pumpWidget(screen(false));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(screen(true));
    await tester.pumpAndSettle();
    expect(find.text('1 : 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

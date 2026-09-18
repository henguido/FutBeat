import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/main.dart';

class TestRepository implements FootballRepository {
  TestRepository({this.fail = false, this.real = false});
  bool fail;
  final bool real;
  @override
  Future<Snapshot> load() async {
    if (fail) throw const SocketException('Offline');
    final json = jsonDecode(
      File('assets/demo.snapshot.json').readAsStringSync(),
    ) as Json;
    if (real) {
      json['demo'] = false;
      json['coverage'] = {
        'source': 'TheSportsDB',
        'partial': true,
        'live': false,
      };
      json['freshness'] = {'stale': true};
      for (final match in json['matches'] as List) {
        match['startTime'] = '2030-01-20T18:00:00Z';
      }
    }
    return Snapshot(json);
  }

  @override
  Future<Snapshot> loadDate(DateTime date) => load();
}

Future<void> openApp(
  WidgetTester tester, {
  String route = '/matches',
  TestRepository? repository,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = createRouter(initialLocation: route);
  final database = AppDatabase(NativeDatabase.memory());
  addTearDown(router.dispose);
  addTearDown(database.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        repositoryProvider.overrideWithValue(repository ?? TestRepository()),
        databaseProvider.overrideWithValue(database),
        preferenceProvider.overrideWith(
          (ref) => Stream.value(
            const CountryPreference(
              detectedCountry: 'CR',
              selectedCountry: null,
              bootstrapDismissed: false,
            ),
          ),
        ),
        followsProvider.overrideWith((ref) => Stream.value(<String>{})),
        temporaryInterestsProvider.overrideWith(
          (ref) => Stream.value(<String>{}),
        ),
      ],
      child: FutBeatApp(router: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'partial provider coverage keeps freshness warning and calendar recovery',
    (tester) async {
      await openApp(tester, repository: TestRepository(real: true));
      expect(
        find.textContaining('Los datos pueden estar desactualizados'),
        findsOneWidget,
      );
      expect(find.text('No hay partidos este día'), findsOneWidget);
      expect(find.byIcon(Icons.calendar_month_outlined), findsOneWidget);
      expect(find.widgetWithText(ActionChip, '20/1/2030'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('FB-US-036: follow from profile appears in favorites', (
    tester,
  ) async {
    final setup = await tester.runAsync(() async {
      final db = AppDatabase(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [
          repositoryProvider.overrideWithValue(TestRepository()),
          databaseProvider.overrideWithValue(db),
        ],
      );
      final subscription = container.listen(
        followsProvider,
        (previous, next) {},
      );
      await container.read(snapshotProvider.future);
      await container
          .read(followsProvider.future)
          .timeout(const Duration(seconds: 10));
      return (db, container, subscription);
    });
    final (db, container, subscription) = setup!;
    final router = createRouter(initialLocation: '/team/fb_team_sap');
    addTearDown(() async {
      router.dispose();
      subscription.close();
      container.dispose();
      await db.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: FutBeatApp(router: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byTooltip('Seguir'),
        ),
      );
      await db
          .watchFollows()
          .firstWhere((items) => items.contains('team:fb_team_sap'))
          .timeout(const Duration(seconds: 10));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Favoritos'));
    await tester.pumpAndSettle();
    expect(find.text('Saprissa'), findsOneWidget);
    expect(find.text('Siguiendo'), findsOneWidget);
  });
  testWidgets('FB-US-001/005/004: match -> team -> competition and back', (
    tester,
  ) async {
    await openApp(tester);
    expect(find.text('Modo demo · resultados ficticios'), findsOneWidget);
    expect(find.text('Último: 64′ · Gol'), findsOneWidget);
    await tester.tap(find.text('2 - 1').first);
    await tester.pumpAndSettle();
    expect(find.text('Match Center'), findsOneWidget);
    await tester.tap(find.text('Saprissa').first);
    await tester.pumpAndSettle();
    expect(find.text('Partidos destacados'), findsOneWidget);
    await tester.tap(find.text('Liga Promerica').first);
    await tester.pumpAndSettle();
    expect(find.text('Apertura 2026 · Demo'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('FB-US-002: empty date and recovery', (tester) async {
    await openApp(tester);
    await tester.tap(find.text('MAÑANA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('En vivo'));
    await tester.pumpAndSettle();
    expect(find.text('No hay partidos este día'), findsOneWidget);
    await tester.tap(find.text('HOY'));
    await tester.tap(find.text('Todos'));
    await tester.pumpAndSettle();
    expect(find.text('2 - 1'), findsOneWidget);
  });
  testWidgets('FB-US-041/042: alias search -> team page', (tester) async {
    await openApp(tester, route: '/explore');
    await tester.enterText(find.byType(TextField), 'LDA');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alajuelense'));
    await tester.pumpAndSettle();
    expect(find.text('Partidos destacados'), findsOneWidget);
  });
  testWidgets('load failure can retry; unknown entity is recoverable', (
    tester,
  ) async {
    final repository = TestRepository(fail: true);
    await openApp(tester, repository: repository);
    expect(find.text('No pudimos cargar esta fecha'), findsOneWidget);
    repository.fail = false;
    await tester.tap(find.text('Reintentar'));
    await tester.pumpAndSettle();
    expect(find.text('2 - 1'), findsOneWidget);
  });
  testWidgets('unknown match shows safe empty state', (tester) async {
    await openApp(tester, route: '/match/invalid');
    expect(find.text('Partido no encontrado'), findsOneWidget);
  });
  testWidgets('360px layout and large text have no overflow', (tester) async {
    await openApp(tester);
    tester.view.physicalSize = const Size(360, 800);
    tester.platformDispatcher.textScaleFactorTestValue = 1.4;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

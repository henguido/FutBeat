import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/push.dart';
import 'package:futbeat/features/onboarding/onboarding_screen.dart';
import 'package:futbeat/main.dart';

Snapshot catalog() => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-09-27T12:00:00Z',
  'competitions': [
    {
      'id': 'competition_global',
      'name': 'Copa Global',
      'country': 'Global',
      'countryCode': 'INT',
      'isGlobalRelevant': true,
      'relevanceScore': 900,
    },
    {
      'id': 'competition_cr',
      'name': 'Liga Costa Rica',
      'country': 'Costa Rica',
      'countryCode': 'CR',
      'relevanceScore': 100,
    },
    {
      'id': 'competition_es',
      'name': 'Liga España',
      'country': 'España',
      'countryCode': 'ES',
      'relevanceScore': 200,
    },
  ],
  'teams': [
    {
      'id': 'team_es',
      'name': 'Equipo España',
      'country': 'España',
      'countryCode': 'ES',
    },
    {
      'id': 'team_cr',
      'name': 'Equipo Costa Rica',
      'country': 'Costa Rica',
      'countryCode': 'CR',
    },
  ],
  'players': [
    {
      'id': 'player_cr',
      'name': 'Jugador Local',
      'country': 'Costa Rica',
      'teamId': 'team_cr',
    },
  ],
  'matches': <dynamic>[],
  'standings': <dynamic>[],
});

Future<void> pumpOnboarding(
  WidgetTester tester, {
  required AppDatabase database,
  double width = 390,
  Set<String> follows = const {},
}) async {
  const preference = CountryPreference(
    detectedCountry: 'CR',
    selectedCountry: null,
    bootstrapDismissed: false,
  );
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        detectedCountryProvider.overrideWithValue('CR'),
        followsProvider.overrideWith((ref) => Stream.value(follows)),
        preferenceProvider.overrideWith((ref) => Stream.value(preference)),
        exploreSnapshotProvider.overrideWith((ref) async => catalog()),
        profileSettingsProvider.overrideWith(
          (ref) async => const UserProfileSettings(notifyGoals: false),
        ),
      ],
      child: const MaterialApp(home: OnboardingScreen()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

void main() {
  Future<void> pumpGate(
    WidgetTester tester, {
    required AppDatabase database,
    required bool dismissed,
  }) async {
    final router = createRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          repositoryProvider.overrideWithValue(DemoRepository()),
          preferenceProvider.overrideWith(
            (ref) => Stream.value(
              CountryPreference(
                detectedCountry: 'CR',
                selectedCountry: null,
                bootstrapDismissed: dismissed,
              ),
            ),
          ),
          followsProvider.overrideWith((ref) => Stream.value(<String>{})),
          profileSettingsProvider.overrideWith(
            (ref) async => const UserProfileSettings(),
          ),
        ],
        child: FutBeatApp(router: router),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
  }

  testWidgets('first launch gate opens onboarding without network', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpGate(tester, database: db, dismissed: false);
    expect(find.text('Bienvenido a FutBeat'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('dismissed gate opens Matches directly', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpGate(tester, database: db, dismissed: true);
    expect(find.text('Partidos'), findsWidgets);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('Skip persists dismissed and enters Matches', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpGate(tester, database: db, dismissed: false);
    await tester.tap(find.text('Saltar'));
    await tester.pump(const Duration(milliseconds: 50));
    final saved = await tester.runAsync(() => db.watchPreference().first);
    expect(saved?.bootstrapDismissed, isTrue);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  test(
    'gate preference defaults to first launch and survives restart',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      expect((await db.watchPreference().first).bootstrapDismissed, isFalse);
      await db.savePreference(
        detectedCountry: 'CR',
        selectedCountry: null,
        bootstrapDismissed: true,
      );
      expect((await db.watchPreference().first).bootstrapDismissed, isTrue);
      await db.close();
    },
  );

  test(
    'country selection and follows persist without duplicate rows',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      await db.savePreference(detectedCountry: 'CR', selectedCountry: 'ES');
      await db.toggle('team', 'team_cr');
      await db.toggle('competition', 'competition_cr');
      expect((await db.watchPreference().first).effectiveCountry, 'ES');
      expect(await db.watchFollows().first, {
        'team:team_cr',
        'competition:competition_cr',
      });
      await db.toggle('team', 'team_cr');
      expect(await db.watchFollows().first, {'competition:competition_cr'});
      await db.close();
    },
  );

  test(
    'country ranking prioritizes local but preserves the global catalog',
    () {
      final ranked = rankOnboardingEntities(catalog().teams, 'CR');
      expect(ranked.map((entity) => entity.id), ['team_cr', 'team_es']);
    },
  );

  test('competition ranking keeps local, global and remaining entries', () {
    final ranked = rankOnboardingEntities(catalog().competitions, 'CR');
    expect(ranked.first.id, 'competition_cr');
    expect(ranked.map((entity) => entity.id).toSet(), {
      'competition_cr',
      'competition_global',
      'competition_es',
    });
  });

  testWidgets('detected country is visible and onboarding has no bottom nav', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.savePreference(detectedCountry: 'CR', selectedCountry: null);
    await pumpOnboarding(tester, database: db);
    expect(find.text('Detectado: Costa Rica'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('Saltar'), findsOneWidget);
  });

  testWidgets('team multi-select and deselect use local follows', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.savePreference(detectedCountry: 'CR', selectedCountry: null);
    await pumpOnboarding(tester, database: db);
    await tester.tap(find.text('Continuar'));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.tap(find.text('Equipo Costa Rica'));
    await tester.pump(const Duration(milliseconds: 20));
    expect(await tester.runAsync(() => db.watchFollows().first), {
      'team:team_cr',
    });
    await tester.tap(find.text('Equipo Costa Rica'));
    await tester.pump(const Duration(milliseconds: 20));
    expect(await tester.runAsync(() => db.watchFollows().first), isEmpty);
  });

  testWidgets('player step has real search and remains optional', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.savePreference(detectedCountry: 'CR', selectedCountry: null);
    await pumpOnboarding(tester, database: db);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('Continuar'));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.widgetWithText(TextField, 'Buscar jugadores'), findsOneWidget);
    expect(find.text('Continuar'), findsOneWidget);
  });

  testWidgets(
    'alerts load existing values and never request permission on open',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.savePreference(detectedCountry: 'CR', selectedCountry: null);
      await pumpOnboarding(tester, database: db);
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.text('Continuar'));
        await tester.pump(const Duration(milliseconds: 20));
      }
      final goals = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Goles'),
      );
      expect(goals.value, isFalse);
      expect(find.textContaining('Podrás activar avisos'), findsOneWidget);
    },
  );

  testWidgets('account step explicitly permits guest continuation', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.savePreference(detectedCountry: 'CR', selectedCountry: null);
    await pumpOnboarding(tester, database: db);
    for (var i = 0; i < 5; i++) {
      await tester.tap(find.text('Continuar'));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.textContaining('continuar como invitado'), findsOneWidget);
    expect(find.text('Ir a Partidos'), findsOneWidget);
  });

  for (final width in [320.0, 360.0, 390.0, 430.0]) {
    testWidgets('responsive onboarding has no overflow at ${width.toInt()}px', (
      tester,
    ) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.savePreference(detectedCountry: 'CR', selectedCountry: null);
      await pumpOnboarding(tester, database: db, width: width);
      expect(tester.takeException(), isNull);
      expect(find.text('Continuar'), findsOneWidget);
    });
  }
}

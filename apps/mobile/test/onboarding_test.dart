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
  CountryPreference preference = const CountryPreference(
    detectedCountry: 'CR',
    selectedCountry: null,
    bootstrapDismissed: false,
  ),
}) async {
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
    'dismissal updates only the gate and preserves country selection',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      await db.savePreference(detectedCountry: 'CR', selectedCountry: 'ES');
      await db.markBootstrapDismissed();
      await db.saveDetectedCountry('US');
      await db.saveSelectedCountry('MX');
      final saved = await db.watchPreference().first;
      expect(saved.detectedCountry, 'US');
      expect(saved.selectedCountry, 'MX');
      expect(saved.bootstrapDismissed, isTrue);
      await db.close();
    },
  );

  test(
    'automatic country refreshes when the device locale changes',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      await db.savePreference(detectedCountry: 'CR', selectedCountry: null);
      final preference = await refreshCountryForLocales(db, const [
        Locale('es', 'ES'),
      ]);
      expect(preference.detectedCountry, 'ES');
      expect(preference.effectiveCountry, 'ES');
      final withoutRegion = await refreshCountryForLocales(db, const [
        Locale('es'),
      ]);
      expect(withoutRegion.detectedCountry, isNull);
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

  test('searched entities preserve backend match-quality order', () {
    final searched = onboardingEntitiesForQuery(catalog().teams, 'CR', 'equipo');
    expect(searched.map((entity) => entity.id), ['team_es', 'team_cr']);
  });

  test('player retries reject stale queries and countries', () {
    const request = (query: 'messi', country: 'CR');
    expect(
      isCurrentOnboardingRequest(
        request,
        currentQuery: 'messi',
        currentCountry: 'CR',
      ),
      isTrue,
    );
    expect(
      isCurrentOnboardingRequest(
        request,
        currentQuery: 'mes',
        currentCountry: 'CR',
      ),
      isFalse,
    );
    expect(
      isCurrentOnboardingRequest(
        request,
        currentQuery: 'messi',
        currentCountry: 'ES',
      ),
      isFalse,
    );
  });

  test('country selector accepts ISO countries but excludes regions', () {
    expect(isSelectableCountryCode('CR'), isTrue);
    expect(isSelectableCountryCode('GB-ENG'), isFalse);
    expect(isSelectableCountryCode('EUROPE'), isFalse);
    expect(onboardingCountryLabel('ES'), 'España');
    expect(onboardingCountryLabel('JP'), 'JP');
  });

  test('dirty Automatic clear is not replaced by a cloud override', () {
    expect(
      reconcileSelectedCountry(local: null, cloud: 'ES', dirty: true),
      isNull,
    );
    expect(
      reconcileSelectedCountry(local: null, cloud: 'ES', dirty: false),
      'ES',
    );
    expect(
      reconcileSelectedCountry(local: 'CR', cloud: 'ES', dirty: false),
      'ES',
    );
    expect(
      reconcileSelectedCountry(local: null, cloud: 'CR', dirty: true),
      isNull,
    );
  });

  test(
    'alert save contains remote failure and still invalidates settings',
    () async {
      var invalidations = 0;
      final saved = await saveOnboardingSettings(
        settings: const UserProfileSettings(notifyGoals: false),
        save: (_) async => throw Exception('offline'),
        invalidate: () => invalidations++,
      );
      expect(saved, isFalse);
      expect(invalidations, 1);
    },
  );

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

  testWidgets('unknown ISO is shown accurately and manual country can reset', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.savePreference(detectedCountry: 'JP', selectedCountry: 'ES');
    await pumpOnboarding(
      tester,
      database: db,
      preference: const CountryPreference(
        detectedCountry: 'JP',
        selectedCountry: 'ES',
        bootstrapDismissed: true,
      ),
    );
    expect(find.text('Detectado: JP'), findsOneWidget);
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Automático (JP)').last);
    await tester.pump(const Duration(milliseconds: 20));
    final saved = await tester.runAsync(() => db.watchPreference().first);
    expect(saved?.selectedCountry, isNull);
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

  testWidgets('changing steps clears visible and debounced search text', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.savePreference(detectedCountry: 'CR', selectedCountry: null);
    await pumpOnboarding(tester, database: db);
    await tester.tap(find.text('Continuar'));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.enterText(find.byType(TextField), 'Manchester');
    await tester.tap(find.text('Continuar'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.widgetWithText(TextField, 'Manchester'), findsNothing);
    expect(
      find.widgetWithText(TextField, 'Buscar competiciones'),
      findsOneWidget,
    );
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

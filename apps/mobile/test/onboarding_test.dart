import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/countries.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/live_realtime.dart';
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
      'domesticTier': 1,
      'isPrimaryDomestic': true,
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
  bool livePreference = false,
  bool offline = false,
  PushService? pushService,
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
        preferenceProvider.overrideWith(
          (ref) => livePreference
              ? database.watchPreference()
              : Stream.value(preference),
        ),
        exploreSnapshotProvider.overrideWith(
          (ref) => offline
              ? Stream<Snapshot>.error(Exception('offline'))
              : Stream.value(catalog()),
        ),
        profileSettingsProvider.overrideWith(
          (ref) async => const UserProfileSettings(notifyGoals: false),
        ),
        if (pushService != null)
          pushServiceProvider.overrideWithValue(pushService),
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

  test('automatic country refreshes when the device locale changes', () async {
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
  });

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
      final ranked = rankOnboardingEntities('team', catalog().teams, 'CR');
      expect(ranked.map((entity) => entity.id), ['team_cr', 'team_es']);
    },
  );

  test('competition ranking keeps local, global and remaining entries', () {
    final ranked = rankOnboardingEntities(
      'competition',
      catalog().competitions,
      'CR',
    );
    expect(ranked.first.id, 'competition_cr');
    expect(ranked.map((entity) => entity.id).toSet(), {
      'competition_cr',
      'competition_global',
      'competition_es',
    });
  });

  test('searched entities preserve backend match-quality order', () {
    final searched = onboardingEntitiesForQuery(
      'team',
      catalog().teams,
      'CR',
      'equipo',
    );
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
    expect(countryDisplayName('ES'), 'España');
    expect(countryDisplayName('jp'), 'Japón');
    expect(countryDisplayName('DE'), 'Alemania');
    expect(countryDisplayName('GB-ENG'), 'Inglaterra');
    expect(countryDisplayName('ZZ'), isNull);
    expect(countryFlag('CR'), '🇨🇷');
    expect(selectableCountryCodes, isNot(contains('GB-ENG')));
    expect(selectableCountryCodes.every(isSelectableCountryCode), isTrue);
    expect(countryMatches('ES', 'espana'), isTrue);
  });

  test('only the manual country is shown, never the device locale', () {
    // Device locale en-US, user chose Costa Rica.
    expect(
      onboardingCountryCode(
        const CountryPreference(
          detectedCountry: 'US',
          selectedCountry: 'CR',
          bootstrapDismissed: false,
        ),
      ),
      'CR',
    );
    expect(
      onboardingCountryCode(
        const CountryPreference(
          detectedCountry: 'US',
          selectedCountry: null,
          bootstrapDismissed: false,
        ),
      ),
      isNull,
    );
    expect(
      onboardingCountryCode(
        const CountryPreference(
          detectedCountry: 'CR',
          selectedCountry: null,
          bootstrapDismissed: false,
        ),
      ),
      isNull,
    );
    expect(
      onboardingCountryCode(
        const CountryPreference(
          detectedCountry: 'ZZ',
          selectedCountry: null,
          bootstrapDismissed: false,
        ),
      ),
      isNull,
    );
    expect(
      onboardingCountryCode(
        const CountryPreference(
          detectedCountry: null,
          selectedCountry: null,
          bootstrapDismissed: false,
        ),
      ),
      isNull,
    );
  });

  test(
    'manual country survives a restart with another device region',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.savePreference(detectedCountry: 'CR', selectedCountry: null);
      await db.saveSelectedCountry('CR');
      // Next launch: the phone now reports en-US.
      final restarted = await refreshDetectedCountry(db, 'US');
      expect(restarted.selectedCountry, 'CR');
      expect(restarted.detectedCountry, 'US');
      expect(onboardingCountryCode(restarted), 'CR');
    },
  );

  test('a device suggestion is never stored as the chosen country', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final first = await refreshDetectedCountry(db, 'US');
    expect(first.selectedCountry, isNull);
    expect(onboardingCountryCode(first), isNull);
    final again = await refreshDetectedCountry(db, 'CR');
    expect(again.selectedCountry, isNull);
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

  Iterable<String> visibleTexts(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '');

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  bool isRawCode(String text) => RegExp(r'^[A-Z]{2}$').hasMatch(text);

  testWidgets('first screen is minimal and onboarding has no bottom nav', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.savePreference(detectedCountry: 'CR', selectedCountry: null);
    await pumpOnboarding(tester, database: db);
    expect(find.text('Bienvenido a FutBeat'), findsOneWidget);
    // Even a locale that matches is never auto-selected.
    expect(find.text('Elegir país'), findsOneWidget);
    expect(find.text('Costa Rica'), findsNothing);
    expect(find.text('Cambiar'), findsNothing);
    expect(find.text('Continuar'), findsOneWidget);
    expect(find.text('Saltar'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    final texts = visibleTexts(tester).join(' | ');
    for (final banned in [
      'Detectado',
      'Automático',
      'ubicación',
      'Usamos',
      'Usaremos',
      'ordenar',
      'ocultar',
      '(opcional)',
    ]) {
      expect(texts, isNot(contains(banned)), reason: banned);
    }
    expect(visibleTexts(tester).where(isRawCode), isEmpty);
  });

  testWidgets('offline: country and steps still work without a catalog', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpOnboarding(tester, database: db, offline: true);
    expect(find.text('Elegir país'), findsOneWidget);
    await tester.tap(find.text('Continuar'));
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('Equipos'), findsOneWidget);
    expect(find.text('Sin conexión'), findsOneWidget);
    expect(find.text('Reintentar'), findsOneWidget);
    await tester.tap(find.text('Continuar'));
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('Competiciones'), findsOneWidget);
  });

  testWidgets('device US without a choice shows Elegir país and saves none', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.savePreference(detectedCountry: 'US', selectedCountry: null);
    await pumpOnboarding(tester, database: db, livePreference: true);
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('Elegir país'), findsOneWidget);
    expect(find.text('Estados Unidos'), findsNothing);
    expect(find.text('Cambiar'), findsNothing);
    await tester.tap(find.text('Continuar'));
    await tester.pump(const Duration(milliseconds: 20));
    final saved = await tester.runAsync(() => db.watchPreference().first);
    expect(saved?.selectedCountry, isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  });

  testWidgets('device US + chosen CR shows Costa Rica', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpOnboarding(
      tester,
      database: db,
      preference: const CountryPreference(
        detectedCountry: 'US',
        selectedCountry: 'CR',
        bootstrapDismissed: false,
      ),
    );
    expect(find.text('Costa Rica'), findsOneWidget);
    expect(find.text('Estados Unidos'), findsNothing);
  });

  testWidgets('unknown device region shows no raw code', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpOnboarding(
      tester,
      database: db,
      preference: const CountryPreference(
        detectedCountry: 'ZZ',
        selectedCountry: null,
        bootstrapDismissed: false,
      ),
    );
    expect(find.text('ZZ'), findsNothing);
    expect(find.text('Elegir país'), findsOneWidget);
  });

  testWidgets('picker lists localized names and saves a manual choice', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.savePreference(detectedCountry: 'US', selectedCountry: null);
    await pumpOnboarding(tester, database: db, livePreference: true);
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('Elegir país'), findsOneWidget);
    expect(find.text('Estados Unidos'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('onboarding-country')));
    await settle(tester);
    expect(find.byKey(const ValueKey('country-picker')), findsOneWidget);
    expect(find.text('Buscar país'), findsOneWidget);
    expect(visibleTexts(tester).where(isRawCode), isEmpty);
    await tester.enterText(
      find.byKey(const ValueKey('country-picker-search')),
      'alem',
    );
    await settle(tester);
    expect(find.text('Alemania'), findsOneWidget);
    expect(find.text('DE'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('country-picker-search')),
      'costa',
    );
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('country-CR')));
    await settle(tester);
    final saved = await tester.runAsync(() => db.watchPreference().first);
    expect(saved?.selectedCountry, 'CR');
    expect(saved?.detectedCountry, 'US');
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('Costa Rica'), findsOneWidget);
    expect(find.text('Estados Unidos'), findsNothing);
    // Unmount so drift's stream-close timer fires inside the test.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  });

  testWidgets('re-entry keeps the manual country and its title', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          detectedCountryProvider.overrideWithValue('US'),
          followsProvider.overrideWith((ref) => Stream.value(<String>{})),
          preferenceProvider.overrideWith(
            (ref) => Stream.value(
              const CountryPreference(
                detectedCountry: 'US',
                selectedCountry: 'CR',
                bootstrapDismissed: true,
              ),
            ),
          ),
          exploreSnapshotProvider.overrideWith(
            (ref) => Stream.value(catalog()),
          ),
          profileSettingsProvider.overrideWith(
            (ref) async => const UserProfileSettings(notifyGoals: false),
          ),
        ],
        child: const MaterialApp(home: OnboardingScreen(reentry: true)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('Personalizar FutBeat'), findsOneWidget);
    expect(find.text('Costa Rica'), findsOneWidget);
    expect(find.text('Estados Unidos'), findsNothing);
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
      expect(find.text('Alertas guardadas'), findsOneWidget);
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
    expect(find.text('Cuenta no disponible'), findsOneWidget);
    expect(find.text('Ir a Partidos'), findsOneWidget);
  });

  testWidgets('configured account step offers an optional guest path', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final db = AppDatabase(NativeDatabase.memory());
    final service = PushService(
      const LiveRealtimeConfig(
        supabaseUrl: 'https://supabase.test',
        publicKey: 'publishable-test-key',
      ),
      db,
      _NoTokens(),
    );
    addTearDown(() async {
      service.dispose();
      await db.close();
    });
    await db.savePreference(detectedCountry: 'CR', selectedCountry: null);
    await pumpOnboarding(tester, database: db, pushService: service);
    for (var i = 0; i < 5; i++) {
      await tester.tap(find.text('Continuar'));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Crear cuenta'), findsOneWidget);
    expect(find.text('Iniciar sesión'), findsOneWidget);
    expect(find.text('Continuar como invitado'), findsOneWidget);
    expect(
      find.textContaining('tus favoritos se guardan en este dispositivo'),
      findsOneWidget,
    );
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

class _NoTokens implements PushTokenSource {
  @override
  Future<String?> requestToken() async => null;

  @override
  Stream<String> get rotations => const Stream.empty();
}

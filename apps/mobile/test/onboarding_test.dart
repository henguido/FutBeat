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

Map<String, dynamic> catalogJson() => {
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
};

Snapshot catalog() => Snapshot(catalogJson());

Future<void> pumpOnboarding(
  WidgetTester tester, {
  required AppDatabase database,
  double width = 390,
  double height = 844,
  Set<String> follows = const {},
  CountryPreference preference = const CountryPreference(
    detectedCountry: 'CR',
    selectedCountry: null,
    bootstrapDismissed: false,
  ),
  bool livePreference = false,
  bool liveFollows = false,
  bool offline = false,
  bool atWelcome = false,
  OnboardingProgressStore? progress,
  PushService? pushService,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        detectedCountryProvider.overrideWithValue('CR'),
        followsProvider.overrideWith(
          (ref) =>
              liveFollows ? database.watchFollows() : Stream.value(follows),
        ),
        onboardingProgressStoreProvider.overrideWithValue(
          progress ?? MemoryProgress(),
        ),
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
        if (pushService != null) ...[
          pushServiceProvider.overrideWithValue(pushService),
          liveRealtimeConfigProvider.overrideWithValue(pushService.config),
        ],
      ],
      child: const MaterialApp(home: OnboardingScreen()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  if (!atWelcome) {
    await tester.tap(find.byKey(const ValueKey('onboarding-quick-setup')));
    await tester.pump(const Duration(milliseconds: 300));
  }
}

class MemoryProgress implements OnboardingProgressStore {
  MemoryProgress([this.step]);
  int? step;
  bool cleared = false;

  @override
  Future<int?> read() async => step;

  @override
  Future<void> write(int value) async => step = value;

  @override
  Future<void> clear() async {
    cleared = true;
    step = null;
  }
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
    expect(
      find.byKey(const ValueKey('onboarding-quick-setup')),
      findsOneWidget,
    );
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('dismissed gate opens Matches directly', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpGate(tester, database: db, dismissed: true);
    expect(find.text('Partidos'), findsWidgets);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('guest / skip persists dismissed and enters Matches', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpGate(tester, database: db, dismissed: false);
    await tester.tap(find.text('Continuar como invitado'));
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
    await pumpOnboarding(tester, database: db, atWelcome: true);
    expect(find.text('Configuración rápida'), findsOneWidget);
    expect(find.text('Continuar como invitado'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.byKey(const ValueKey('onboarding-quick-setup')));
    await tester.pump(const Duration(milliseconds: 300));
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
    expect(find.text('Ligas'), findsOneWidget);
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
    expect(find.widgetWithText(TextField, 'Buscar ligas'), findsOneWidget);
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
        find.widgetWithText(SwitchListTile, 'Gol'),
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
    expect(find.text('Continuar'), findsOneWidget);
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
    expect(find.text('Continuar sin cuenta'), findsOneWidget);
    expect(
      find.text(
        'Sincroniza favoritos, preferencias, notificaciones y Premium.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('account step shows the session once signed in from Perfil', (
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
    await tester.runAsync(service.restore);
    await db.savePreference(detectedCountry: 'CR', selectedCountry: null);
    await pumpOnboarding(tester, database: db, pushService: service);
    for (var i = 0; i < 5; i++) {
      await tester.tap(find.text('Continuar'));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Crear cuenta'), findsOneWidget);

    // Signed in (e.g. from Perfil): the step updates by itself.
    service.session = {
      'access_token': 'access',
      'refresh_token': 'refresh',
      'user': {'id': 'user-a', 'email': 'qa@example.com'},
    };
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('Sesión iniciada · qa@example.com'), findsOneWidget);
    expect(find.text('Crear cuenta'), findsNothing);
    expect(find.text('Continuar'), findsOneWidget);
  });

  group('onboarding v2', () {
    /// Lets Drift streams (real async) emit, then finishes transitions.
    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
    }

    /// Unmounts and lets Drift close its stream queries (their timers).
    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    }

    Future<void> next(WidgetTester tester, [int times = 1]) async {
      for (var i = 0; i < times; i++) {
        await tester.tap(find.byKey(const ValueKey('onboarding-next')));
        await settle(tester);
      }
    }

    testWidgets('restart resumes the step where it was left', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final progress = MemoryProgress(OnboardingStep.competitions);
      await pumpOnboarding(
        tester,
        database: db,
        atWelcome: true,
        progress: progress,
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Ligas'), findsOneWidget);
      await next(tester);
      expect(progress.step, OnboardingStep.players);
    });

    testWidgets('leagues and players persist as follows', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.savePreference(detectedCountry: 'CR', selectedCountry: null);
      await db.addFollows({'team:team_cr'});
      await pumpOnboarding(tester, database: db, liveFollows: true);
      await settle(tester);
      await next(tester, 2); // → Ligas
      await tester.tap(find.text('Liga Costa Rica'));
      await settle(tester);
      await next(tester); // → Jugadores (from the followed team)
      expect(find.text('DE TUS EQUIPOS'), findsOneWidget);
      await tester.tap(find.text('Jugador Local'));
      await settle(tester);
      expect(await tester.runAsync(() => db.watchFollows().first), {
        'team:team_cr',
        'competition:competition_cr',
        'player:player_cr',
      });
      await unmount(tester);
    });

    testWidgets('back / forward keeps one follow and shows the count', (
      tester,
    ) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.savePreference(detectedCountry: 'CR', selectedCountry: null);
      await pumpOnboarding(tester, database: db, liveFollows: true);
      await settle(tester);
      await next(tester); // → Equipos
      await tester.tap(find.text('Equipo Costa Rica'));
      await settle(tester);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('onboarding-selected-count')),
            )
            .data,
        '1',
      );
      await next(tester);
      await tester.tap(find.byTooltip('Atrás'));
      await settle(tester);
      expect(find.text('Equipos'), findsOneWidget);
      final selected = tester.widget<Semantics>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('onboarding-team-team_cr')),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(selected.properties.selected, isTrue);
      await next(tester);
      expect(await tester.runAsync(() => db.watchFollows().first), {
        'team:team_cr',
      });
      await unmount(tester);
    });

    testWidgets('offline, the whole flow still reaches Partidos', (
      tester,
    ) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final progress = MemoryProgress();
      await pumpOnboarding(
        tester,
        database: db,
        offline: true,
        progress: progress,
      );
      await next(tester, 6); // country → … → summary, with no catalog
      expect(find.text('Todo listo'), findsOneWidget);
      final go = tester.widget<FilledButton>(
        find.byKey(const ValueKey('onboarding-next')),
      );
      expect(go.onPressed, isNotNull);
      expect(find.text('Ir a Partidos'), findsOneWidget);
      expect(progress.step, OnboardingStep.summary);
    });

    testWidgets('summary shows country and follow counts', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await pumpOnboarding(
        tester,
        database: db,
        preference: const CountryPreference(
          detectedCountry: 'CR',
          selectedCountry: 'CR',
          bootstrapDismissed: false,
        ),
        follows: const {
          'team:team_cr',
          'team:team_es',
          'competition:competition_cr',
          'player:player_cr',
        },
      );
      await next(tester, 6);
      Text value(String key) => tester.widget<Text>(
        find
            .descendant(
              of: find.byKey(ValueKey('onboarding-summary-$key')),
              matching: find.byType(Text),
            )
            .last,
      );
      expect(value('country').data, 'Costa Rica');
      expect(value('teams').data, '2');
      expect(value('competitions').data, '1');
      expect(value('players').data, '1');
    });
  });

  testWidgets('welcome scrolls in landscape without overflow', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpOnboarding(
      tester,
      database: db,
      width: 800,
      height: 360,
      atWelcome: true,
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('Continuar como invitado'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Continuar como invitado'), findsOneWidget);
  });

  testWidgets('summary truncates a long country name at 320px', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpOnboarding(
      tester,
      database: db,
      width: 320,
      preference: const CountryPreference(
        detectedCountry: 'CD',
        selectedCountry: 'CD',
        bootstrapDismissed: false,
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.tap(find.byKey(const ValueKey('onboarding-next')));
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.text('Todo listo'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('P2: duplicate leagues', () {
    Entity comp(
      String id,
      String name,
      String code, {
      Map<String, Object?> extra = const {},
    }) => Entity({
      'id': id,
      'name': name,
      'countryCode': code,
      'country': code,
      ...extra,
    });

    test('an acronym alias of the same country is one card, with the logo', () {
      final choices = collapseOnboardingDuplicates('competition', [
        comp('c_mls_long', 'Major League Soccer', 'US'),
        comp(
          'c_mls',
          'MLS',
          'US',
          extra: {
            'media': {
              'url': 'https://example.test/mls.png',
              'verificationStatus': 'VERIFIED',
            },
          },
        ),
        comp('c_usl', 'USL Championship', 'US'),
      ]);
      expect(choices, hasLength(2));
      expect(choices.first.ids, {'c_mls_long', 'c_mls'});
      expect(choices.last.ids, {'c_usl'});
    });

    test('short names / aliases and redirects merge; other leagues never', () {
      final choices = collapseOnboardingDuplicates('competition', [
        comp(
          'a',
          'Liga Promerica',
          'CR',
          extra: {'shortName': 'Primera División'},
        ),
        comp('b', 'Primera División', 'CR'),
        comp('c', 'Copa Costa Rica', 'CR'),
        comp('d', 'Primera División', 'ES'), // same name, other country
        comp('e', 'Premier League', 'GB-ENG'),
        comp('f', 'Old Premier id', 'GB-ENG'),
        comp('g', 'XY', 'CR'), // nobody's initials
      ], resolve: (id) => id == 'f' ? 'e' : id);
      expect(
        [for (final c in choices) c.ids],
        [
          {'a', 'b'},
          {'c'},
          {'d'},
          {'e', 'f'},
          {'g'},
        ],
      );
      // The canonical entity is the one shown.
      expect(choices[3].entity.id, 'e');
    });

    test('alias chains collapse into one card, whatever the order', () {
      final choices = collapseOnboardingDuplicates('competition', [
        comp(
          'a',
          'Liga X',
          'CR',
          extra: {
            'aliases': ['Liga Y'],
          },
        ),
        comp('c', 'Liga Z', 'CR'),
        comp(
          'b',
          'Liga Y',
          'CR',
          extra: {
            'aliases': ['Liga Z'],
          },
        ),
      ]);
      expect(choices, hasLength(1));
      expect(choices.single.ids, {'a', 'b', 'c'});
    });

    test('a stale alias row carries its canonical id for follows', () {
      final choices = collapseOnboardingDuplicates('competition', [
        comp('alias_a', 'Liga Promerica', 'CR'),
      ], resolve: (id) => id == 'alias_a' ? 'canonical_c' : id);
      // A follow stored as `competition:canonical_c` selects this card, and
      // a new follow is stored under the canonical id.
      expect(choices.single.ids, {'alias_a', 'canonical_c'});
      expect(choices.single.canonicalId, 'canonical_c');
    });

    testWidgets('one card for duplicates, the existing follow stays selected', (
      tester,
    ) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.addFollows({'competition:competition_cr_dup'});
      final raw = catalogJson();
      final data = Snapshot({
        ...raw,
        'competitions': [
          ...(raw['competitions'] as List),
          {
            'id': 'competition_cr_dup',
            'name': 'LCR',
            'country': 'Costa Rica',
            'countryCode': 'CR',
          },
        ],
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            detectedCountryProvider.overrideWithValue('CR'),
            followsProvider.overrideWith(
              (ref) => Stream.value({'competition:competition_cr_dup'}),
            ),
            preferenceProvider.overrideWith(
              (ref) => Stream.value(
                const CountryPreference(
                  detectedCountry: 'CR',
                  selectedCountry: 'CR',
                  bootstrapDismissed: false,
                ),
              ),
            ),
            exploreSnapshotProvider.overrideWith((ref) => Stream.value(data)),
            profileSettingsProvider.overrideWith(
              (ref) async => const UserProfileSettings(),
            ),
            onboardingProgressStoreProvider.overrideWithValue(
              MemoryProgress(OnboardingStep.competitions),
            ),
          ],
          child: const MaterialApp(home: OnboardingScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Ligas'), findsOneWidget);
      // "LCR" = initials of "Liga Costa Rica" (same country): one card.
      expect(find.text('LCR'), findsNothing);
      expect(find.text('Liga Costa Rica'), findsOneWidget);
      final card = tester.widget<Semantics>(
        find
            .ancestor(
              of: find.byKey(
                const ValueKey('onboarding-competition-competition_cr'),
              ),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(card.properties.selected, isTrue);
      // Unfollowing the card removes the duplicate's follow too.
      await tester.tap(find.text('Liga Costa Rica'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(await tester.runAsync(() => db.watchFollows().first), isEmpty);
    });
  });

  group('P2: player suggestions', () {
    Entity player(String id, String team, {String country = ''}) =>
        Entity({'id': id, 'name': 'P $id', 'teamId': team, 'country': country});

    test('players of the chosen teams come first', () {
      final sections = onboardingPlayerSuggestions(
        [player('1', 't1'), player('2', 't2'), player('3', 't1')],
        {'t1'},
        null,
        fill: 2,
      );
      expect(sections.single.label, 'De tus equipos');
      expect([for (final p in sections.single.players) p.id], ['1', '3']);
    });

    test('no players for the chosen teams: real fallback, country first', () {
      final sections = onboardingPlayerSuggestions(
        [
          player('x', 'other'),
          player('cr', 'other', country: 'Costa Rica'),
          player('x', 'other'), // duplicate id
        ],
        {'t1'},
        'CR',
      );
      expect(sections.single.label, 'Destacados');
      expect([for (final p in sections.single.players) p.id], ['cr', 'x']);
    });

    test('few team players are completed without repeating them', () {
      final sections = onboardingPlayerSuggestions(
        [player('1', 't1'), player('2', 'other'), player('1', 't1')],
        {'t1'},
        null,
      );
      expect(
        [for (final s in sections) s.label],
        ['De tus equipos', 'Más jugadores'],
      );
      expect(
        [
          for (final s in sections)
            for (final p in s.players) p.id,
        ],
        ['1', '2'],
      );
    });

    test('no catalog players: nothing invented', () {
      expect(onboardingPlayerSuggestions(const [], {'t1'}, 'CR'), isEmpty);
    });

    testWidgets('fallback shows real players and keeps follows selected', (
      tester,
    ) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await pumpOnboarding(
        tester,
        database: db,
        follows: const {'team:team_es', 'player:player_cr'},
        progress: MemoryProgress(OnboardingStep.players),
        atWelcome: true,
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Jugadores'), findsOneWidget);
      // No player of team_es in the catalog: real fallback, not empty.
      expect(find.text('DESTACADOS'), findsOneWidget);
      expect(find.text('Jugador Local'), findsOneWidget);
      final card = tester.widget<Semantics>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('onboarding-player-player_cr')),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(card.properties.selected, isTrue);
      expect(
        find.widgetWithText(TextField, 'Buscar jugadores'),
        findsOneWidget,
      );
    });
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

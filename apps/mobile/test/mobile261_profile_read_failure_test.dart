import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/entitlements.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/push.dart';
import 'package:futbeat/features/profile/account_security_screen.dart';
import 'package:futbeat/features/profile/notifications_screen_v2.dart';
import 'package:futbeat/features/profile/profile_screen.dart';
import 'package:futbeat/features/profile/personalization_screen.dart';
import 'package:futbeat/features/onboarding/onboarding_screen.dart';

import 'onboarding_test.dart' show MemoryProgress, catalog;

class _NoTokens implements PushTokenSource {
  @override
  Future<String?> currentToken() async => null;
  @override
  Future<String?> requestToken() async => null;
  @override
  Stream<String> get rotations => const Stream.empty();
}

class _ReadFailure extends FlutterSecureStorage {
  bool fail = true;
  bool failWrite = false;
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (key == 'futbeat.profile.settings' && failWrite) {
      throw PlatformException(code: 'synthetic-write-locked');
    }
    return super.write(
      key: key,
      value: value,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (key == 'futbeat.profile.settings' && fail) {
      fail = false;
      throw PlatformException(code: 'synthetic-storage-locked');
    }
    return super.read(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }
}

class _RealProfileService extends PushService {
  _RealProfileService(AppDatabase db, Dio dio, this.testStorage)
    : super(
        const LiveRealtimeConfig(
          supabaseUrl: 'https://fixture.invalid',
          publicKey: 'synthetic',
        ),
        db,
        _NoTokens(),
        dio: dio,
        pushConfigured: false,
      ) {
    session = {
      'access_token': 'synthetic',
      'user': {'id': 'local-fixture'},
    };
  }
  final FlutterSecureStorage testStorage;
  int completedReads = 0;
  @override
  FlutterSecureStorage get storage => testStorage;
  @override
  Future<void> restore() async {}
  @override
  Future<UserProfileSettings> loadProfileSettings() async {
    try {
      return await super.loadProfileSettings();
    } finally {
      completedReads++;
    }
  }
}

class _FreePlan extends EntitlementsController {
  @override
  Entitlements build() => const Entitlements(accountKey: 'guest');
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const saved = UserProfileSettings(
    displayName: 'Guardado',
    notifyGoals: false,
    notifyKickoff: false,
    hourFormat: '24h',
  );
  late AppDatabase db;
  late Dio dio;
  late _RealProfileService service;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({
      'futbeat.profile.settings': jsonEncode(saved.toJson()),
    });
    db = AppDatabase(NativeDatabase.memory());
    dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            handler.resolve(
              Response(requestOptions: request, data: <String, dynamic>{}),
            );
          },
        ),
      );
    service = _RealProfileService(db, dio, _ReadFailure());
  });
  tearDown(() async {
    service.dispose();
    await db.close();
  });

  for (final raw in <String?>[null, 'not-json', '[]']) {
    test(
      'missing/malformed legacy profile retains default contract: $raw',
      () async {
        (service.testStorage as _ReadFailure).fail = false;
        FlutterSecureStorage.setMockInitialValues(
          raw == null ? {} : {'futbeat.profile.settings': raw},
        );
        expect(
          (await service.loadProfileSettings()).toJson(),
          const UserProfileSettings().toJson(),
        );
        expect(
          await service.storage.read(key: 'futbeat.profile.settings'),
          raw,
        );
      },
    );
  }

  testWidgets('Profile exposes unreadable preferences as an error with retry', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        pushServiceProvider.overrideWithValue(service),
        entitlementsProvider.overrideWith(_FreePlan.new),
        followsProvider.overrideWith((ref) => Stream.value(const <String>{})),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ProfileScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.text('Reintentar'), findsOneWidget);
    await tester.tap(find.text('Reintentar'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.text('Guardado'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'onboarding alerts offer retry instead of editing unknown settings',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          pushServiceProvider.overrideWithValue(service),
          databaseProvider.overrideWithValue(db),
          onboardingProgressStoreProvider.overrideWithValue(
            MemoryProgress(OnboardingStep.alerts),
          ),
          followsProvider.overrideWith((ref) => Stream.value(const <String>{})),
          preferenceProvider.overrideWith(
            (ref) => Stream.value(
              const CountryPreference(
                selectedCountry: 'CR',
                detectedCountry: 'CR',
                bootstrapDismissed: false,
              ),
            ),
          ),
          exploreSnapshotProvider.overrideWith(
            (ref) => Stream.value(catalog()),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: OnboardingScreen()),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.byType(SwitchListTile), findsNothing);
      expect(find.text('Reintentar'), findsOneWidget);
      await tester.tap(find.text('Reintentar'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.byType(SwitchListTile), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed notification save and unreadable recovery do not throw', (
    tester,
  ) async {
    final storage = service.testStorage as _ReadFailure;
    storage.fail = false;
    final container = ProviderContainer(
      overrides: [pushServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: NotificationsScreenV2()),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    storage.failWrite = true;
    storage.fail = true;
    await tester.tap(find.byKey(const ValueKey('notification-notify_goals')));
    await _flush(tester);
    expect(
      find.text('No pudimos comprobar el cambio. Inténtalo nuevamente.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed hour save and unreadable recovery restore the last known value',
    (tester) async {
      final storage = service.testStorage as _ReadFailure;
      storage.fail = false;
      final container = ProviderContainer(
        overrides: [
          pushServiceProvider.overrideWithValue(service),
          profileSettingsProvider.overrideWith((ref) async => saved),
          followsProvider.overrideWith((ref) => Stream.value(const <String>{})),
          preferenceProvider.overrideWith(
            (ref) => Stream.value(
              const CountryPreference(
                selectedCountry: 'CR',
                detectedCountry: 'CR',
                bootstrapDismissed: true,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: PersonalizationScreen()),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      final field = find.byType(DropdownButtonFormField<String>);
      await tester.scrollUntilVisible(
        field,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      storage.failWrite = true;
      storage.fail = true;
      tester.widget<DropdownButtonFormField<String>>(field).onChanged!('12h');
      await _flush(tester);
      expect(tester.state<FormFieldState<String>>(field).value, '24h');
      expect(
        find.text('No pudimos comprobar el cambio. Inténtalo nuevamente.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'profile IO failure is not an absent profile with default preferences',
    () async {
      await expectLater(
        service.loadProfileSettings(),
        throwsA(isA<PlatformException>()),
      );
      expect((await service.loadProfileSettings()).notifyGoals, isFalse);
    },
  );

  test(
    'a name edit must not replace unreadable persisted alerts with defaults',
    () async {
      try {
        final profile = await service.loadProfileSettings();
        await service.saveProfileSettings(
          profile.copyWith(displayName: 'Nuevo nombre'),
        );
      } on PlatformException {
        // An unavailable profile must be retried, never edited from defaults.
      }
      final profile = await service.loadProfileSettings();
      expect(profile.notifyGoals, isFalse);
      expect(profile.notifyKickoff, isFalse);
      expect(profile.hourFormat, '24h');
    },
  );

  testWidgets(
    'name editing cannot overwrite stored alerts after a real read error',
    (tester) async {
      final container = ProviderContainer(
        overrides: [pushServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: AccountSecurityScreen()),
        ),
      );
      await tester.pump();
      await tester.pump();
      for (var i = 0; i < 20 && service.completedReads == 0; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump();
      expect(service.completedReads, greaterThan(0));
      final save = find.byKey(const ValueKey('account-name-save'));
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      await tester.tap(find.text('Reintentar'));
      for (var i = 0; i < 20 && service.completedReads < 2; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump();
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('account-name')))
            .controller!
            .text,
        'Guardado',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'notification preferences expose read error and recover without defaults',
    (tester) async {
      final container = ProviderContainer(
        overrides: [pushServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: NotificationsScreenV2()),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(SwitchListTile), findsNothing);
      expect(find.text('Reintentar'), findsOneWidget);
      await tester.tap(find.text('Reintentar'));
      await tester.pump();
      final goal = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('notification-notify_goals')),
      );
      expect(goal.value, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}

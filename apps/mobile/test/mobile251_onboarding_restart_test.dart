import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/push.dart';
import 'package:futbeat/features/onboarding/onboarding_screen.dart';
import 'package:futbeat/features/profile/personalization_screen.dart';
import 'package:futbeat/features/explore/explore_screen.dart';
import 'package:futbeat/main.dart';
import 'package:go_router/go_router.dart';

import 'onboarding_test.dart' show catalog;

class _NoTokens251 implements PushTokenSource {
  @override
  Future<String?> currentToken() async => null;
  @override
  Future<String?> requestToken() async => throw StateError('Push out of scope');
  @override
  Stream<String> get rotations => const Stream.empty();
}

class _Catalog251 implements FootballRepository {
  @override
  Future<Snapshot> load() async => catalog();
  @override
  Future<Snapshot> loadDate(DateTime date) async => catalog();
  @override
  Future<MatchDetail> loadMatchDetail(String id) async => MatchDetail.empty(id);
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  expect(finder.hitTestable(), findsOneWidget);
  await tester.tap(finder);
  await _flush(tester);
  expect(tester.takeException(), isNull, reason: 'after tapping $finder');
}

class _App251 {
  _App251(
    this.db,
    this.router,
    this.scope,
    this.service,
    this.dio,
    this.requests,
  );
  final AppDatabase db;
  final GoRouter router;
  final ProviderContainer scope;
  final PushService service;
  final Dio dio;
  final List<String> requests;
  bool _closed = false;

  static Future<_App251> open(
    WidgetTester tester,
    File file,
    String detected, {
    AppDatabase? existingDatabase,
  }) async {
    final db = existingDatabase ?? AppDatabase(NativeDatabase(file));
    await tester.runAsync(() => db.customSelect('select 1').get());
    final requests = <String>[];
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          requests.add(request.path);
          handler.reject(
            DioException(requestOptions: request, error: 'No remote requests'),
          );
        },
      ),
    );
    final service = PushService(
      const LiveRealtimeConfig(
        supabaseUrl: 'https://fixture.invalid',
        publicKey: 'synthetic-local-key',
      ),
      db,
      _NoTokens251(),
      dio: dio,
      pushConfigured: false,
    );
    final router = createRouter(initialLocation: '/start');
    final scope = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        repositoryProvider.overrideWithValue(_Catalog251()),
        detectedCountryProvider.overrideWithValue(detected),
        pushServiceProvider.overrideWithValue(service),
        liveRealtimeConfigProvider.overrideWithValue(
          const LiveRealtimeConfig(supabaseUrl: '', publicKey: ''),
        ),
        liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
        playerSuggestionsProvider.overrideWith(
          (ref, teams) async => catalog().players,
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: scope,
        child: FutBeatApp(router: router),
      ),
    );
    await _flush(tester);
    return _App251(db, router, scope, service, dio, requests);
  }

  Future<void> close(WidgetTester tester) async {
    if (_closed) return;
    _closed = true;
    await tester.pumpWidget(const SizedBox());
    scope.dispose();
    router.dispose();
    service.dispose();
    dio.close(force: true);
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(db.close);
  }
}

void main() {
  testWidgets(
    'A03/M02: country picker preserves concurrently saved favourite order',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final db = AppDatabase(NativeDatabase.memory());
      await tester.runAsync(
        () => db.savePreference(
          detectedCountry: 'CR',
          selectedCountry: 'CR',
          bootstrapDismissed: true,
        ),
      );
      final service = PushService(
        const LiveRealtimeConfig(supabaseUrl: '', publicKey: ''),
        db,
        _NoTokens251(),
        pushConfigured: false,
      );
      var closed = false;
      Future<void> close() async {
        if (closed) return;
        closed = true;
        await tester.pumpWidget(const SizedBox());
        service.dispose();
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(db.close);
      }

      addTearDown(close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            detectedCountryProvider.overrideWithValue('CR'),
            pushServiceProvider.overrideWithValue(service),
          ],
          child: const MaterialApp(home: PersonalizationScreen()),
        ),
      );
      await _flush(tester);
      await _tap(tester, find.text('País'));
      // Another existing preference owner commits while the picker is open.
      await tester.runAsync(
        () => db.savePreference(
          competitionOrderMode: 'manual',
          pinnedCompetitionIds: ['competition_es', 'competition_cr'],
        ),
      );
      await _flush(tester);
      await tester.enterText(
        find.byKey(const ValueKey('country-picker-search')),
        'España',
      );
      await _flush(tester);
      await _tap(tester, find.byKey(const ValueKey('country-ES')));
      final saved = (await tester.runAsync(() => db.watchPreference().first))!;
      expect(saved.selectedCountry, 'ES');
      expect(saved.competitionOrderMode, 'manual');
      expect(saved.pinnedCompetitionIds, ['competition_es', 'competition_cr']);
      expect(saved.bootstrapDismissed, isTrue);
      await close();
    },
  );

  testWidgets(
    'A03/A07: guest country edited from Profile survives account linking',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase(NativeDatabase.memory());
      await tester.runAsync(() async {
        await db.savePreference(
          detectedCountry: 'CR',
          selectedCountry: 'CR',
          bootstrapDismissed: true,
        );
        await db.addFollows({'team:team_cr', 'player:player_cr'});
      });
      final app = await _App251.open(
        tester,
        File('unused-memory-db'),
        'CR',
        existingDatabase: db,
      );
      addTearDown(() => app.close(tester));
      await _tap(
        tester,
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Perfil'),
        ),
      );
      final customize = find.text('Personalizar FutBeat');
      await tester.scrollUntilVisible(
        customize,
        250,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('profile-root')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await _tap(tester, customize);
      expect(find.byType(PersonalizationScreen), findsOneWidget);
      await _tap(tester, find.text('País'));
      await tester.enterText(
        find.byKey(const ValueKey('country-picker-search')),
        'España',
      );
      await _flush(tester);
      await _tap(tester, find.byKey(const ValueKey('country-ES')));
      expect(
        (await tester.runAsync(() => db.watchPreference().first))!
            .selectedCountry,
        'ES',
      );

      var cloudCountry = 'MX';
      final unknown = <String>[];
      app.dio.interceptors.clear();
      app.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            final path = request.uri.path;
            app.requests.add(path);
            Object? data = <String, dynamic>{};
            if (path.endsWith('/auth/v1/token')) {
              data = {
                'access_token': 'synthetic-access251',
                'refresh_token': 'synthetic-refresh251',
                'expires_in': 3600,
                'user': {
                  'id': 'synthetic-user251',
                  'email': 'fixture@example.test',
                },
              };
            } else if (path.endsWith('futbeat_read_user_profile')) {
              data = {
                'preferences': {
                  'detectedCountry': 'MX',
                  'selectedCountry': cloudCountry,
                },
                'follows': [
                  {'type': 'competition', 'id': 'competition_cr'},
                ],
              };
            } else if (path.endsWith('futbeat_sync_user_preference_fields')) {
              final body = request.data as Map;
              if (body['p_update_selected'] == true) {
                cloudCountry = body['p_selected'] as String;
              }
            } else if (!path.endsWith('futbeat_sync_push_follows') &&
                !path.endsWith('futbeat_sync_user_profile_v3')) {
              unknown.add(path);
              handler.reject(
                DioException(
                  requestOptions: request,
                  error: 'Unexpected fixture request',
                ),
              );
              return;
            }
            handler.resolve(
              Response(requestOptions: request, statusCode: 200, data: data),
            );
          },
        ),
      );
      var linked = false;
      Object? linkingError;
      unawaited(
        app.service
            .signIn('fixture@example.test', 'synthetic-password251')
            .then(
              (_) => linked = true,
              onError: (Object error) {
                linkingError = error;
                linked = true;
              },
            ),
      );
      // Pump both Drift's widget-zone streams and real file IO. Awaiting the
      // entire login inside runAsync would starve the existing stream queries.
      for (var i = 0; i < 40 && !linked; i++) {
        await _flush(tester);
      }
      expect(
        linked,
        isTrue,
        reason: 'link must settle within the bounded local fixture',
      );
      expect(linkingError, isNull);
      expect(app.service.authenticated, isTrue);
      expect(unknown, isEmpty);
      expect((await tester.runAsync(() => db.watchFollows().first)), {
        'team:team_cr',
        'player:player_cr',
        'competition:competition_cr',
      });
      expect(
        (await tester.runAsync(() => db.watchPreference().first))!
            .selectedCountry,
        'ES',
      );
      expect(cloudCountry, 'ES');
      await app.close(tester);
    },
  );

  testWidgets(
    'A01-A07/M02: complete setup, SQLite reopen and Profile personalization',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = await tester.runAsync(
        () => Directory.systemTemp.createTemp('futbeat-mobile251-'),
      );
      final file = File.fromUri(directory!.uri.resolve('preferences.sqlite'));
      _App251? app;
      addTearDown(() async {
        if (app != null) await app.close(tester);
        await tester.runAsync(() async {
          final resolved = await directory.resolveSymbolicLinks();
          final tempRoot = await Directory.systemTemp.resolveSymbolicLinks();
          if (!resolved.startsWith(tempRoot + Platform.pathSeparator)) {
            throw StateError(
              'Refusing cleanup outside the temporary directory',
            );
          }
          await directory.delete(recursive: true);
        });
      });
      app = await _App251.open(tester, file, 'CR');
      expect(
        find.byKey(const ValueKey('onboarding-quick-setup')),
        findsOneWidget,
      );
      await _tap(tester, find.byKey(const ValueKey('onboarding-quick-setup')));
      expect(find.text('SUGERIDO'), findsOneWidget);
      expect(find.text('Costa Rica'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('onboarding-country')));
      final picker = find.byType(CountryPickerSheet);
      await tester.enterText(
        find.descendant(of: picker, matching: find.byType(TextField)),
        'Costa Rica',
      );
      await _flush(tester);
      await _tap(tester, find.byKey(const ValueKey('country-CR')));
      expect(
        (await tester.runAsync(() => app!.db.watchPreference().first))!
            .selectedCountry,
        'CR',
      );

      Future<void> next() =>
          _tap(tester, find.byKey(const ValueKey('onboarding-next')));
      await next();
      final team = find.byKey(const ValueKey('onboarding-team-team_cr'));
      await _tap(tester, team);
      await _tap(tester, team);
      await _tap(tester, team);
      await next();
      await _tap(
        tester,
        find.byKey(const ValueKey('onboarding-competition-competition_cr')),
      );
      await next();
      await _tap(
        tester,
        find.byKey(const ValueKey('onboarding-player-player_cr')),
      );
      await next();
      final goals = find.widgetWithText(
        SwitchListTile,
        'Avísame cuando haya un gol',
      );
      final newGoalPreference = !tester.widget<SwitchListTile>(goals).value;
      await _tap(tester, goals);
      expect(
        (await tester.runAsync(app.service.loadProfileSettings))!.notifyGoals,
        newGoalPreference,
      );
      await next();
      expect(
        find.byKey(const ValueKey('onboarding-account-login')),
        findsOneWidget,
      );
      expect(
        find.textContaining('También puedes continuar como invitado'),
        findsOneWidget,
      );
      await next();
      for (final type in ['teams', 'competitions', 'players']) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey('onboarding-summary-$type')),
            matching: find.text('1'),
          ),
          findsOneWidget,
        );
      }
      await next();
      expect(app.router.routeInformationProvider.value.uri.path, '/matches');
      expect(find.byType(NavigationBar), findsOneWidget);
      final expected = {
        'team:team_cr',
        'competition:competition_cr',
        'player:player_cr',
      };
      expect(
        await tester.runAsync(() => app!.db.watchFollows().first),
        expected,
      );
      expect(
        (await tester.runAsync(() => app!.db.select(app.db.follows).get()))!
            .length,
        3,
      );
      expect(app.requests, isEmpty);
      await app.close(tester);
      app = null;

      // New DB, service, container and router: no in-memory/provider reuse.
      app = await _App251.open(tester, file, 'US');
      expect(app.router.routeInformationProvider.value.uri.path, '/matches');
      expect(
        find.byKey(const ValueKey('onboarding-quick-setup')),
        findsNothing,
      );
      final restored = (await tester.runAsync(
        () => app!.db.watchPreference().first,
      ))!;
      expect(restored.bootstrapDismissed, isTrue);
      expect(restored.selectedCountry, 'CR');
      expect(restored.detectedCountry, 'US');
      expect(
        await tester.runAsync(() => app!.db.watchFollows().first),
        expected,
      );
      expect(
        (await tester.runAsync(app.service.loadProfileSettings))!.notifyGoals,
        newGoalPreference,
      );
      expect(app.service.authenticated, isFalse);
      await _tap(
        tester,
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Perfil'),
        ),
      );
      final customize = find.text('Personalizar FutBeat');
      await tester.scrollUntilVisible(
        customize,
        250,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('profile-root')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await _tap(tester, customize);
      expect(find.byType(PersonalizationScreen), findsOneWidget);
      for (final key in [
        'personalize-teams',
        'personalize-competitions',
        'personalize-players',
        'personalize-alerts',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }
      for (final type in ['teams', 'competitions', 'players']) {
        await _tap(tester, find.byKey(ValueKey('personalize-$type')));
        expect(find.byType(ExploreScreen), findsOneWidget);
        app.router.pop();
        await _flush(tester);
        expect(find.byType(PersonalizationScreen), findsOneWidget);
      }
      await _tap(tester, find.byKey(const ValueKey('personalize-alerts')));
      expect(
        tester
            .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, 'Avísame cuando haya un gol'),
            )
            .value,
        newGoalPreference,
      );
      app.router.pop();
      await _flush(tester);
      expect(app.requests, isEmpty);
      expect(tester.takeException(), isNull);
      await app.close(tester);
      app = null;
    },
  );
}

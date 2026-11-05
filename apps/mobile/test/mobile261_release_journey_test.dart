import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/push.dart';
import 'package:futbeat/features/onboarding/onboarding_screen.dart';
import 'package:futbeat/main.dart';
import 'package:futbeat/features/profile/personalization_screen.dart';
import 'package:go_router/go_router.dart';

const _guest = {
  'team:fb_team_guest',
  'competition:fb_comp_guest',
  'player:fb_player_guest',
};
const _h = 'team:fb_team_h';
Set<String> _accountFollows(String id) => {
  'team:fb_team_$id',
  'competition:fb_comp_$id',
  'player:fb_player_$id',
};

class _NoPush implements PushTokenSource {
  var requests = 0;
  @override
  Future<String?> currentToken() async => null;
  @override
  Future<String?> requestToken() async {
    requests++;
    throw StateError('Push is outside journey scope');
  }

  @override
  Stream<String> get rotations => const Stream.empty();
}

class _Cloud {
  final follows = {'A': _accountFollows('A'), 'B': _accountFollows('B')};
  final profiles = {
    'A': const UserProfileSettings(
      displayName: 'Synthetic account A',
      hourFormat: '12h',
    ).toJson(),
    'B': const UserProfileSettings(
      displayName: 'Synthetic account B',
      hourFormat: '12h',
    ).toJson(),
  };
  final selected = <String, String?>{'A': 'MX', 'B': 'GB'};
  final detected = <String, String?>{'A': 'MX', 'B': 'GB'};
  final accessOwners = <String, String>{};
  final refreshOwners = <String, String>{};
  final paths = <String>[];
  final unknown = <String>[];
  var serial = 0;
  Map<String, dynamic> issue(String uid) {
    final access = 'synthetic-access-$uid-${++serial}';
    final refresh = 'synthetic-refresh-$uid-$serial';
    accessOwners[access] = uid;
    refreshOwners[refresh] = uid;
    return {
      'access_token': access,
      'refresh_token': refresh,
      'expires_at':
          DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
          1000,
      'user': {
        'id': uid,
        'email': '${uid.toLowerCase()}@fixture.invalid',
        'email_confirmed_at': '2026-11-03T00:00:00Z',
      },
    };
  }

  void attach(Dio dio) {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          final path = request.uri.path;
          paths.add(path);
          try {
            Object? data = <String, dynamic>{};
            final body = request.data is Map
                ? request.data as Map
                : <String, dynamic>{};
            if (path.endsWith('/auth/v1/token')) {
              final uid =
                  request.uri.queryParameters['grant_type'] == 'refresh_token'
                  ? refreshOwners[body['refresh_token']]
                  : body['email'] == 'a@fixture.invalid'
                  ? 'A'
                  : body['email'] == 'b@fixture.invalid'
                  ? 'B'
                  : null;
              if (uid == null) {
                throw StateError('Unexpected synthetic auth request');
              }
              data = issue(uid);
            } else if (path.endsWith('/auth/v1/logout')) {
              data = null;
            } else {
              final auth = '${request.headers['Authorization']}'.replaceFirst(
                'Bearer ',
                '',
              );
              final uid = accessOwners[auth];
              if (uid == null) {
                throw StateError('Missing synthetic account owner');
              }
              if (path.endsWith('futbeat_read_user_profile')) {
                data = {
                  'preferences': {
                    ...profiles[uid]!,
                    'selectedCountry': selected[uid],
                    'detectedCountry': detected[uid],
                  },
                  'follows': [
                    for (final key in follows[uid]!)
                      {
                        'type': key.split(':').first,
                        'id': key.substring(key.indexOf(':') + 1),
                      },
                  ],
                };
              } else if (path.endsWith('futbeat_sync_push_follows')) {
                follows[uid] = {
                  for (final row in body['p_follows'] as List)
                    '${row['type']}:${row['id']}',
                };
              } else if (path.endsWith('futbeat_sync_user_profile_v3')) {
                profiles[uid] = Map<String, dynamic>.from(
                  body['p_profile'] as Map,
                );
              } else if (path.endsWith('futbeat_sync_user_preference_fields')) {
                if (body['p_update_selected'] == true) {
                  selected[uid] = body['p_selected'] as String?;
                }
                if (body['p_update_detected'] == true) {
                  detected[uid] = body['p_detected'] as String?;
                }
              } else {
                unknown.add(path);
                throw StateError('Unexpected synthetic route');
              }
            }
            handler.resolve(
              Response(requestOptions: request, statusCode: 200, data: data),
            );
          } catch (error) {
            handler.reject(DioException(requestOptions: request, error: error));
          }
        },
      ),
    );
  }
}

class _Catalog implements FootballRepository {
  final data = Snapshot({
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': '2026-11-03T18:00:00Z',
    'teams': [
      for (final id in ['guest', 'A', 'B', 'h'])
        {'id': 'fb_team_$id', 'name': 'Synthetic team $id', 'country': 'CR'},
    ],
    'competitions': [
      for (final id in ['guest', 'A', 'B'])
        {
          'id': 'fb_comp_$id',
          'name': 'Synthetic competition $id',
          'country': 'CR',
        },
    ],
    'players': [
      for (final id in ['guest', 'A', 'B'])
        {
          'id': 'fb_player_$id',
          'name': 'Synthetic player $id',
          'country': 'CR',
        },
    ],
    'matches': [],
    'standings': [],
  });
  @override
  Future<Snapshot> load() async => data;
  @override
  Future<Snapshot> loadDate(DateTime date) async => data;
  @override
  Future<MatchDetail> loadMatchDetail(String id) async => MatchDetail.empty(id);
}

Future<void> _until(
  WidgetTester tester,
  bool Function() condition,
  String reason,
) async {
  for (var turn = 0; turn < 250 && !condition(); turn++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue, reason: reason);
}

Future<void> _operation(
  WidgetTester tester,
  Future<void> operation,
  String label,
) async {
  var done = false;
  Object? failure;
  StackTrace? stack;
  unawaited(
    operation.then(
      (_) => done = true,
      onError: (Object error, StackTrace trace) {
        failure = error;
        stack = trace;
        done = true;
      },
    ),
  );
  await _until(tester, () => done, label);
  if (failure != null) Error.throwWithStackTrace(failure!, stack!);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  expect(finder.hitTestable(), findsOneWidget);
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 300));
}

class _App {
  _App(this.db, this.service, this.tokens, this.dio, this.scope, this.router);
  final AppDatabase db;
  final PushService service;
  final _NoPush tokens;
  final Dio dio;
  final ProviderContainer scope;
  final GoRouter router;
  bool closed = false;
  static Future<_App> open(
    WidgetTester tester,
    File file,
    _Cloud cloud, {
    bool seedGuest = false,
  }) async {
    final db = AppDatabase(NativeDatabase(file));
    await tester.runAsync(() => db.customSelect('SELECT 1').get());
    final dio = Dio();
    cloud.attach(dio);
    final tokens = _NoPush();
    final service = PushService(
      const LiveRealtimeConfig(
        supabaseUrl: 'https://fixture.invalid',
        publicKey: 'synthetic-public',
      ),
      db,
      tokens,
      dio: dio,
      pushConfigured: false,
      oauthEnabled: false,
    );
    if (seedGuest) {
      await tester.runAsync(
        () => db.savePreference(
          detectedCountry: 'CR',
          selectedCountry: 'CR',
          bootstrapDismissed: true,
        ),
      );
      await tester.runAsync(() => db.addFollows(_guest));
      await _operation(
        tester,
        service.saveProfileSettings(
          const UserProfileSettings(hourFormat: '24h', notifyGoals: false),
        ),
        'seed guest profile',
      );
      await _operation(
        tester,
        service.markSelectedCountryDirty(),
        'seed guest country choice',
      );
    }
    await _operation(tester, service.restore(), 'restore local session');
    final router = createRouter(initialLocation: '/profile');
    final scope = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        repositoryProvider.overrideWithValue(_Catalog()),
        pushServiceProvider.overrideWithValue(service),
        detectedCountryProvider.overrideWithValue('CR'),
        liveRealtimeConfigProvider.overrideWithValue(
          const LiveRealtimeConfig(supabaseUrl: '', publicKey: ''),
        ),
        liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: scope,
        child: FutBeatApp(router: router),
      ),
    );
    await _until(
      tester,
      () => find.text('Personalizar FutBeat').evaluate().isNotEmpty,
      'profile ready',
    );
    return _App(db, service, tokens, dio, scope, router);
  }

  Future<void> settle(WidgetTester tester) async {
    await _operation(tester, service.pending, 'account queue');
    await _operation(tester, service.countryPending, 'country queue');
    await tester.pump();
  }

  Future<void> personalize(WidgetTester tester) async {
    while (router.canPop()) {
      router.pop();
      await tester.pump(const Duration(milliseconds: 300));
    }
    router.go('/profile');
    await tester.pump(const Duration(milliseconds: 300));
    await _until(
      tester,
      () => find.text('Personalizar FutBeat').evaluate().isNotEmpty,
      'profile access',
    );
    await _tap(tester, find.text('Personalizar FutBeat'));
    await _until(
      tester,
      () =>
          find.byKey(const ValueKey('personalize-teams')).evaluate().isNotEmpty,
      'personalization access',
    );
    // Imperative context.push need not update the URL; verify the visible route.
    expect(find.byType(PersonalizationScreen), findsOneWidget);
    expect(router.canPop(), isTrue);
  }

  Future<void> login(WidgetTester tester, String uid) async {
    while (router.canPop()) {
      router.pop();
      await tester.pump(const Duration(milliseconds: 300));
    }
    router.go('/profile');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 1800));
    await tester.pump(const Duration(milliseconds: 300));
    await _until(
      tester,
      () => find.text('Iniciar sesión').evaluate().isNotEmpty,
      'guest login entry',
    );
    await _tap(tester, find.text('Iniciar sesión'));
    await _until(
      tester,
      () => find.byKey(const ValueKey('auth-email')).evaluate().isNotEmpty,
      'email login form',
    );
    await tester.enterText(
      find.byKey(const ValueKey('auth-email')),
      '${uid.toLowerCase()}@fixture.invalid',
    );
    await tester.enterText(
      find.byKey(const ValueKey('auth-password')),
      'synthetic-password-261',
    );
    debugPrint('JOURNEY submit prepared');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 300));
    await _tap(tester, find.byKey(const ValueKey('auth-submit')));
    await _until(
      tester,
      () =>
          service.userId == uid &&
          find.byKey(const ValueKey('auth-submit')).evaluate().isEmpty,
      'account $uid login completed',
    );
    await settle(tester);
  }

  Future<void> close(WidgetTester tester) async {
    if (closed) return;
    closed = true;
    await tester.pumpWidget(const SizedBox());
    scope.dispose();
    router.dispose();
    service.dispose();
    dio.close(force: true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await _operation(tester, db.close(), 'SQLite connection closed');
  }
}

// Each simulated installation owns its secure storage as well as its SQLite
// file. A global secure-storage mock would make two clients share a session.
class _InstallStorage extends FlutterSecureStorage {
  final values = <String, String>{};
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];
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
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }
}

class _IndependentInstall {
  _IndependentInstall(this.db, this.service, this.tokens);
  final AppDatabase db;
  final PushService service;
  final _NoPush tokens;
  bool closed = false;
  static Future<_IndependentInstall> open(
    File file,
    _InstallStorage storage,
    _Cloud cloud,
  ) async {
    final db = AppDatabase(NativeDatabase(file));
    await db.customSelect('SELECT 1').get();
    final dio = Dio();
    cloud.attach(dio);
    final tokens = _NoPush();
    final service = PushService(
      const LiveRealtimeConfig(
        supabaseUrl: 'https://fixture.invalid',
        publicKey: 'synthetic-public',
      ),
      db,
      tokens,
      dio: dio,
      secureStorage: storage,
      pushConfigured: false,
      oauthEnabled: false,
    );
    await service.restore();
    return _IndependentInstall(db, service, tokens);
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    await service.pending;
    await service.countryPending;
    service.dispose();
    await db.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('same public config, two simultaneous installations retain separate sessions and guest preferences', () async {
    final directory = await Directory.systemTemp.createTemp(
      'futbeat-two-installs-',
    );
    final cloud = _Cloud();
    final storageA = _InstallStorage();
    final storageB = _InstallStorage();
    final fileA = File.fromUri(directory.uri.resolve('a.sqlite'));
    final fileB = File.fromUri(directory.uri.resolve('b.sqlite'));
    final installs = <_IndependentInstall>[];
    addTearDown(() async {
      for (final install in installs) {
        await install.close();
      }
      final path = await directory.resolveSymbolicLinks();
      final tempRoot = await Directory.systemTemp.resolveSymbolicLinks();
      if (!path.startsWith(tempRoot + Platform.pathSeparator)) {
        throw StateError('Unsafe fixture cleanup');
      }
      await directory.delete(recursive: true);
    });
    var a = await _IndependentInstall.open(fileA, storageA, cloud);
    installs.add(a);
    var b = await _IndependentInstall.open(fileB, storageB, cloud);
    installs.add(b);
    expect(a.service.authenticated, isFalse);
    expect(b.service.authenticated, isFalse);
    expect(
      cloud.paths,
      isEmpty,
      reason: 'local guest must not create an Auth account implicitly',
    );
    const guestA = {'team:fb_team_guest_A', 'player:fb_player_guest_A'};
    const guestB = {'team:fb_team_guest_B', 'competition:fb_comp_guest_B'};
    await Future.wait([
      a.db.addFollows(guestA),
      b.db.addFollows(guestB),
      a.db.savePreference(detectedCountry: 'CR', selectedCountry: 'CR'),
      b.db.savePreference(detectedCountry: 'ES', selectedCountry: 'ES'),
      a.service.saveProfileSettings(
        const UserProfileSettings(hourFormat: '24h', notifyGoals: false),
      ),
      b.service.saveProfileSettings(
        const UserProfileSettings(hourFormat: '12h', notifyFinal: false),
      ),
    ]);
    await Future.wait([
      a.service.markSelectedCountryDirty(),
      b.service.markSelectedCountryDirty(),
    ]);
    await Future.wait([
      a.service.signIn('a@fixture.invalid', 'synthetic-password'),
      b.service.signIn('b@fixture.invalid', 'synthetic-password'),
    ]);
    await Future.wait([
      a.service.pending,
      b.service.pending,
      a.service.countryPending,
      b.service.countryPending,
    ]);
    final ownedA = {...guestA, ..._accountFollows('A')};
    final ownedB = {...guestB, ..._accountFollows('B')};
    expect(await a.db.watchFollows().first, ownedA);
    expect(await b.db.watchFollows().first, ownedB);
    expect(cloud.follows['A'], ownedA);
    expect(cloud.follows['B'], ownedB);
    expect(
      a.service.session!['access_token'],
      isNot(b.service.session!['access_token']),
    );
    expect(
      jsonDecode(storageA.values['futbeat.push.session']!)['user']['id'],
      'A',
    );
    expect(
      jsonDecode(storageB.values['futbeat.push.session']!)['user']['id'],
      'B',
    );
    await Future.wait([a.close(), b.close()]);
    a = await _IndependentInstall.open(fileA, storageA, cloud);
    installs.add(a);
    b = await _IndependentInstall.open(fileB, storageB, cloud);
    installs.add(b);
    await Future.wait([
      a.service.pending,
      b.service.pending,
      a.service.countryPending,
      b.service.countryPending,
    ]);
    expect(a.service.userId, 'A');
    expect(b.service.userId, 'B');
    expect(await a.db.watchFollows().first, ownedA);
    expect(await b.db.watchFollows().first, ownedB);
    expect((await a.db.watchPreference().first).selectedCountry, 'CR');
    expect((await b.db.watchPreference().first).selectedCountry, 'ES');
    expect((await a.service.loadProfileSettings()).notifyGoals, isFalse);
    expect((await b.service.loadProfileSettings()).notifyFinal, isFalse);
    await a.service.signOut();
    await a.service.signOutCleanup;
    expect(a.service.authenticated, isFalse);
    expect(b.service.userId, 'B');
    expect(
      jsonDecode(storageB.values['futbeat.push.session']!)['user']['id'],
      'B',
    );
    expect(await b.db.watchFollows().first, ownedB);
    expect(cloud.unknown, isEmpty);
    expect(a.tokens.requests + b.tokens.requests, 0);
    await Future.wait([a.close(), b.close()]);
  });

  testWidgets(
    'guest to account A reopen logout guest edit account B reopen preserves ownership',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(420, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('futbeat-journey261-'),
      ))!;
      final file = File.fromUri(directory.uri.resolve('preferences.sqlite'));
      final cloud = _Cloud();
      _App? app;
      addTearDown(() async {
        if (app != null) await app.close(tester);
        await tester.runAsync(() async {
          final path = await directory.resolveSymbolicLinks();
          final root = await Directory.systemTemp.resolveSymbolicLinks();
          if (!path.startsWith(root + Platform.pathSeparator)) {
            throw StateError('Unsafe fixture cleanup');
          }
          await directory.delete(recursive: true);
        });
      });
      app = await _App.open(tester, file, cloud, seedGuest: true);
      expect(app.service.authenticated, isFalse);
      await app.personalize(tester);
      expect(
        (await tester.runAsync(() => app!.db.watchFollows().first)),
        _guest,
      );
      debugPrint('JOURNEY guest configured');
      await app.login(tester, 'A');
      debugPrint('JOURNEY A linked');
      final ownedA = {..._guest, ..._accountFollows('A')};
      expect(await tester.runAsync(() => app!.db.watchFollows().first), ownedA);
      expect(cloud.follows['A'], ownedA);
      expect(cloud.selected['A'], 'CR');
      expect(
        (await tester.runAsync(app.service.loadProfileSettings))!.displayName,
        'Synthetic account A',
      );
      debugPrint('JOURNEY close');
      await app.close(tester);
      debugPrint('JOURNEY closed');
      debugPrint('JOURNEY reopen');
      app = await _App.open(tester, file, cloud);
      debugPrint('JOURNEY reopened');
      expect(app.service.userId, 'A');
      expect(await tester.runAsync(() => app!.db.watchFollows().first), ownedA);
      await app.personalize(tester);
      app.router.go('/profile');
      await tester.pump(const Duration(milliseconds: 300));
      await _tap(tester, find.text('Cuenta y seguridad'));
      await _until(
        tester,
        () =>
            find.byKey(const ValueKey('account-logout')).evaluate().isNotEmpty,
        'logout control',
      );
      await _tap(tester, find.byKey(const ValueKey('account-logout')));
      await _until(tester, () => !app!.service.authenticated, 'A logout');
      await _until(
        tester,
        () => find.text('Sesión cerrada.').evaluate().isNotEmpty,
        'durable logout UI completion',
      );
      await _operation(
        tester,
        app.service.signOutCleanup,
        'A server logout completed',
      );
      await tester.runAsync(() => app!.db.addFollows({_h}));
      await app.personalize(tester);
      await _tap(tester, find.text('País'));
      await _until(
        tester,
        () => find.byType(CountryPickerSheet).evaluate().isNotEmpty,
        'country picker',
      );
      await tester.enterText(
        find.byKey(const ValueKey('country-picker-search')),
        'España',
      );
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(milliseconds: 300));
      await _tap(tester, find.byKey(const ValueKey('country-ES')));
      await _until(
        tester,
        () => find.byType(CountryPickerSheet).evaluate().isEmpty,
        'country saved',
      );
      await _tap(tester, find.byKey(const ValueKey('personalize-alerts')));
      final finalAlert = find.byKey(
        const ValueKey('notification-notify_final'),
      );
      await _until(
        tester,
        () => finalAlert.evaluate().isNotEmpty,
        'local alert preferences',
      );
      await _tap(tester, finalAlert);
      await _until(
        tester,
        () => !tester.widget<SwitchListTile>(finalAlert).value,
        'guest changed final alert',
      );
      await app.login(tester, 'B');
      final ownedB = {_h, ..._accountFollows('B')};
      expect(await tester.runAsync(() => app!.db.watchFollows().first), ownedB);
      expect(
        cloud.follows['A'],
        ownedA,
        reason: 'switch must not modify A server follows',
      );
      expect(cloud.follows['B'], ownedB);
      expect(
        (await tester.runAsync(() => app!.db.watchPreference().first))!
            .selectedCountry,
        'ES',
      );
      expect(cloud.selected['B'], 'ES');
      final bBefore = (await tester.runAsync(app.service.loadProfileSettings))!;
      expect(bBefore.notifyFinal, isFalse);
      expect(app.service.enabled, isFalse);
      expect(app.tokens.requests, 0);
      debugPrint('JOURNEY close');
      await app.close(tester);
      debugPrint('JOURNEY closed');
      debugPrint('JOURNEY reopen');
      app = await _App.open(tester, file, cloud);
      debugPrint('JOURNEY reopened');
      expect(app.service.userId, 'B');
      expect(await tester.runAsync(() => app!.db.watchFollows().first), ownedB);
      expect(
        (await tester.runAsync(() => app!.db.watchPreference().first))!
            .selectedCountry,
        'ES',
      );
      final bAfter = (await tester.runAsync(app.service.loadProfileSettings))!;
      expect(bAfter.notifyFinal, isFalse);
      await app.personalize(tester);
      expect(find.byKey(const ValueKey('personalize-players')), findsOneWidget);
      expect(cloud.unknown, isEmpty);
      expect(
        cloud.paths.where((path) => path.endsWith('futbeat_register_push')),
        isEmpty,
      );
      expect(app.tokens.requests, 0);
      // Account-specific identity must not be carried over by a guest editing
      // an unrelated device alert preference after signing out of A.
      expect(bBefore.displayName, 'Synthetic account B');
      expect(bAfter.displayName, 'Synthetic account B');
      expect(cloud.profiles['B']!['displayName'], 'Synthetic account B');
      expect(tester.takeException(), isNull);
      // Widget-test timer invariants run before addTearDown: dispose the final
      // authenticated service here, just as for the preceding process restarts.
      await app.close(tester);
    },
  );
}

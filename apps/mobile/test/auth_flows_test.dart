import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/auth_errors.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/push.dart';
import 'package:futbeat/features/profile/password_reset_sheet.dart';
import 'package:futbeat/features/profile/profile_screen.dart';

class _Tokens implements PushTokenSource {
  @override
  Future<String?> requestToken() async => null;

  @override
  Stream<String> get rotations => const Stream.empty();
}

/// A failed request: an HTTP status with a GoTrue-style body, or no
/// response at all (offline).
class _Fail {
  const _Fail(this.status, [this.body = const <String, dynamic>{}]);
  const _Fail.offline() : status = null, body = const <String, dynamic>{};
  final int? status;
  final Map<String, dynamic> body;
}

/// A signed-in session that needs no server round trip (widget tests).
Map<String, dynamic> _session() => {
  'access_token': 'access-user-a-0',
  'refresh_token': 'refresh-user-a-0',
  'user': {
    'id': 'user-a',
    'email': 'user@example.com',
    'email_confirmed_at': '2026-09-27T00:00:00Z',
  },
};

typedef _Route = FutureOr<Object?> Function(RequestOptions options);

/// Stateful fake of GoTrue + PostgREST: per-user server follows, rotating
/// refresh tokens (a reused one fails like GoTrue), and overridable routes.
class _Http {
  _Http() {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          calls.add(options);
          final route = routes.entries
              .where((entry) => options.path.contains(entry.key))
              .map((entry) => entry.value)
              .firstOrNull;
          final result = route == null
              ? <String, dynamic>{}
              : await route(options);
          if (result is _Fail) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: result.status == null
                    ? DioExceptionType.connectionError
                    : DioExceptionType.badResponse,
                response: result.status == null
                    ? null
                    : Response(
                        requestOptions: options,
                        statusCode: result.status,
                        data: result.body,
                      ),
              ),
            );
            return;
          }
          handler.resolve(
            Response(requestOptions: options, statusCode: 200, data: result),
          );
        },
      ),
    );
    routes.addAll({
      'grant_type=password': signInRoute,
      'grant_type=refresh_token': refreshRoute,
      'futbeat_read_user_profile': readRoute,
      'futbeat_sync_push_follows': syncRoute,
      'futbeat_register_push': (_) => null,
      '/auth/v1/logout': logoutRoute,
    });
  }

  final dio = Dio();
  final calls = <RequestOptions>[];
  final routes = <String, _Route>{};
  final users = {
    'user@example.com': 'user-a',
    'b@example.com': 'user-b',
    'c@example.com': 'user-c',
  };
  final server = <String, Set<String>>{};
  final validRefresh = <String, String>{};
  final refreshOf = <String, String>{};
  DateTime now = DateTime.utc(2026, 9, 29, 12);
  var _issued = 0;

  Map<String, dynamic> issue(String uid) {
    _issued++;
    final refresh = 'refresh-$uid-$_issued';
    validRefresh[refresh] = uid;
    refreshOf['access-$uid-$_issued'] = refresh;
    return {
      'access_token': 'access-$uid-$_issued',
      'refresh_token': refresh,
      'expires_at':
          now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
      'user': {
        'id': uid,
        'email': users.entries.firstWhere((e) => e.value == uid).key,
        'email_confirmed_at': '2026-09-27T00:00:00Z',
      },
    };
  }

  Object? signInRoute(RequestOptions options) {
    final uid = users[(options.data as Map)['email']];
    return uid == null
        ? const _Fail(400, {'error_code': 'invalid_credentials'})
        : issue(uid);
  }

  Object? refreshRoute(RequestOptions options) {
    final uid = validRefresh.remove((options.data as Map)['refresh_token']);
    return uid == null
        ? const _Fail(400, {'error_code': 'refresh_token_already_used'})
        : issue(uid);
  }

  /// GoTrue logout: scope=local revokes only the calling session; the
  /// default (global) scope revokes every session of the user.
  Object? logoutRoute(RequestOptions options) {
    final access = '${options.headers['Authorization']}'.replaceFirst(
      'Bearer ',
      '',
    );
    if (options.path.contains('scope=local')) {
      validRefresh.remove(refreshOf[access]);
    } else {
      final uid = _caller(options);
      validRefresh.removeWhere((_, owner) => owner == uid);
    }
    return null;
  }

  String _caller(RequestOptions options) {
    final bearer = '${options.headers['Authorization']}'.replaceFirst(
      'Bearer access-',
      '',
    );
    return bearer.substring(0, bearer.lastIndexOf('-'));
  }

  Object? readRoute(RequestOptions options) => {
    'preferences': <String, dynamic>{},
    'follows': [
      for (final key in server[_caller(options)] ?? const <String>{})
        {
          'type': key.substring(0, key.indexOf(':')),
          'id': key.substring(key.indexOf(':') + 1),
        },
    ],
  };

  Object? syncRoute(RequestOptions options) {
    server[_caller(options)] = _followsOf(options);
    return null;
  }

  /// Wraps the current handler of [route] so it waits for the completer.
  Completer<void> hold(String route) {
    final gate = Completer<void>();
    final inner = routes[route]!;
    routes[route] = (options) async {
      await gate.future;
      return inner(options);
    };
    return gate;
  }

  static Set<String> _followsOf(RequestOptions call) => {
    for (final item in (call.data as Map)['p_follows'] as List)
      '${item['type']}:${item['id']}',
  };

  List<Set<String>> get pushes => [
    for (final call in calls)
      if (call.path.endsWith('futbeat_sync_push_follows')) _followsOf(call),
  ];

  int count(String suffix) =>
      calls.where((c) => c.path.contains(suffix)).length;
  bool called(String suffix) => count(suffix) > 0;

  Future<void> waitFor(String suffix) async {
    for (var i = 0; i < 200 && !called(suffix); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(called(suffix), isTrue, reason: 'waiting for $suffix');
  }
}

Future<({PushService service, AppDatabase db, _Http http})> _service({
  Map<String, String> storage = const {},
  Set<String> local = const {},
  Set<String> server = const {},
  _Http? http,
  Duration cleanupTimeout = const Duration(seconds: 5),
}) async {
  FlutterSecureStorage.setMockInitialValues(Map.of(storage));
  final db = AppDatabase(NativeDatabase.memory());
  await db.addFollows(local);
  final fake = http ?? _Http();
  if (server.isNotEmpty) fake.server['user-a'] = {...server};
  final service = PushService(
    const LiveRealtimeConfig(
      supabaseUrl: 'https://supabase.test',
      publicKey: 'publishable-test-key',
    ),
    db,
    _Tokens(),
    dio: fake.dio,
    clock: () => fake.now,
    signOutCleanupTimeout: cleanupTimeout,
  );
  addTearDown(() async {
    service.dispose();
    await db.close();
  });
  return (service: service, db: db, http: fake);
}

/// A service whose storage already holds a valid session for user-a.
Future<({PushService service, AppDatabase db, _Http http})> _stored({
  Set<String> local = const {},
  Set<String> server = const {},
  Duration expiresIn = const Duration(hours: 1),
}) async {
  final http = _Http();
  final session = http.issue('user-a');
  session['expires_at'] =
      http.now.add(expiresIn).millisecondsSinceEpoch ~/ 1000;
  return _service(
    storage: {'futbeat.push.session': jsonEncode(session)},
    local: local,
    server: server,
    http: http,
  );
}

Future<String?> _read(String key) =>
    const FlutterSecureStorage().read(key: key);

Future<void> _settle(PushService service) async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await service.pending;
  }
}

DioException _dio({int? status, Object? body, DioExceptionType? type}) {
  final options = RequestOptions(path: '/auth/v1/token');
  return DioException(
    requestOptions: options,
    type: type ?? DioExceptionType.badResponse,
    response: status == null
        ? null
        : Response(requestOptions: options, statusCode: status, data: body),
  );
}

final _emptySnapshot = Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-09-27T00:00:00Z',
  'competitions': <dynamic>[],
  'teams': <dynamic>[],
  'players': <dynamic>[],
  'matches': <dynamic>[],
  'standings': <dynamic>[],
});

Future<void> _pumpProfile(
  WidgetTester tester,
  PushService service,
  AppDatabase db,
) async {
  tester.view.physicalSize = const Size(800, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        pushServiceProvider.overrideWithValue(service),
        databaseProvider.overrideWithValue(db),
        followsProvider.overrideWith((ref) => Stream.value(<String>{})),
        preferenceProvider.overrideWith(
          (ref) => Stream.value(
            const CountryPreference(
              detectedCountry: null,
              selectedCountry: null,
              bootstrapDismissed: true,
            ),
          ),
        ),
        snapshotProvider.overrideWith((ref) async => _emptySnapshot),
        favoritesSnapshotProvider.overrideWith(
          (ref, keys) async => _emptySnapshot,
        ),
      ],
      child: const MaterialApp(home: ProfileScreen()),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _scrollTo(WidgetTester tester, Finder finder) => tester
    .scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);

void main() {
  group('authErrorMessage', () {
    final cases = <String, (Object, String)>{
      'invalid_credentials': (
        _dio(status: 400, body: {'error_code': 'invalid_credentials'}),
        'Correo o contraseña incorrectos.',
      ),
      'legacy invalid_grant': (
        _dio(
          status: 400,
          body: {
            'error': 'invalid_grant',
            'error_description': 'Invalid login credentials',
          },
        ),
        'Correo o contraseña incorrectos.',
      ),
      'email_not_confirmed': (
        _dio(status: 400, body: {'code': 'email_not_confirmed'}),
        'Confirma tu correo para iniciar sesión.',
      ),
      'legacy not confirmed': (
        _dio(
          status: 400,
          body: {
            'error': 'invalid_grant',
            'error_description': 'Email not confirmed',
          },
        ),
        'Confirma tu correo para iniciar sesión.',
      ),
      'user_already_exists': (
        _dio(status: 422, body: {'error_code': 'user_already_exists'}),
        'Ese correo ya tiene una cuenta. Inicia sesión.',
      ),
      'email_exists': (
        _dio(status: 422, body: {'code': 'email_exists'}),
        'Ese correo ya tiene una cuenta. Inicia sesión.',
      ),
      'weak_password': (
        _dio(status: 422, body: {'error_code': 'weak_password'}),
        'La contraseña es muy débil (mínimo 8 caracteres).',
      ),
      '429': (
        _dio(status: 429, body: const <String, dynamic>{}),
        'Demasiados intentos. Espera un momento.',
      ),
      'over_email_send_rate_limit': (
        _dio(status: 400, body: {'error_code': 'over_email_send_rate_limit'}),
        'Demasiados intentos. Espera un momento.',
      ),
      'over_request_rate_limit': (
        _dio(status: 400, body: {'code': 'over_request_rate_limit'}),
        'Demasiados intentos. Espera un momento.',
      ),
      'signup_disabled': (
        _dio(status: 422, body: {'error_code': 'signup_disabled'}),
        'El registro no está disponible.',
      ),
      'string body': (
        _dio(status: 400, body: jsonEncode({'error_code': 'weak_password'})),
        'La contraseña es muy débil (mínimo 8 caracteres).',
      ),
      'connection error': (
        _dio(type: DioExceptionType.connectionError),
        'Sin conexión. Inténtalo de nuevo.',
      ),
      'timeout': (
        _dio(type: DioExceptionType.receiveTimeout),
        'Sin conexión. Inténtalo de nuevo.',
      ),
      '500': (
        _dio(status: 500, body: const <String, dynamic>{}),
        'No se pudo completar la operación.',
      ),
      'non-dio': (StateError('x'), 'No se pudo completar la operación.'),
    };
    for (final entry in cases.entries) {
      test(entry.key, () {
        expect(authErrorMessage(entry.value.$1), entry.value.$2);
      });
    }
  });

  test('auth rejection: 400/401 always, 403 only with a GoTrue code', () {
    expect(isAuthRejection(_dio(status: 400, body: {})), isTrue);
    expect(isAuthRejection(_dio(status: 401, body: {})), isTrue);
    expect(isAuthRejection(_dio(status: 403, body: {})), isFalse);
    expect(isAuthRejection(_dio(status: 403, body: '<html>')), isFalse);
    for (final code in [
      'refresh_token_not_found',
      'refresh_token_already_used',
      'session_not_found',
      'invalid_grant',
      'bad_jwt',
    ]) {
      expect(
        isAuthRejection(_dio(status: 403, body: {'error_code': code})),
        isTrue,
        reason: code,
      );
    }
    expect(isAuthRejection(_dio(status: 503, body: {})), isFalse);
    expect(
      isAuthRejection(_dio(type: DioExceptionType.connectionError)),
      isFalse,
    );
  });

  test('client validation messages', () {
    expect(validateEmail('user@example.com'), isNull);
    expect(validateEmail('  user@example.com '), isNull);
    expect(validateEmail('user@'), 'Escribe un correo válido.');
    expect(validateEmail(''), 'Escribe un correo válido.');
    expect(validatePassword('', signUp: false), 'Escribe tu contraseña.');
    expect(validatePassword('short', signUp: false), isNull);
    expect(validatePassword('short', signUp: true), 'Mínimo 8 caracteres.');
    expect(validatePassword('12345678', signUp: true), isNull);
  });

  group('sign out', () {
    test(
      'a failing logout still clears the session and keeps follows',
      () async {
        final value = await _service(local: {'team:guest'});
        await value.service.signIn('user@example.com', 'password-test');
        value.http.routes['/auth/v1/logout'] = (_) => const _Fail.offline();

        await value.service.signOut();
        await value.service.signOutCleanup;

        expect(value.http.called('/auth/v1/logout'), isTrue);
        expect(value.service.authenticated, isFalse);
        expect(value.service.renewal, isNull);
        expect(value.service.follows, isNull);
        expect(await _read('futbeat.push.session'), isNull);
        expect(await _read(PushService.pushedKey('user-a')), isNull);
        expect(await value.db.watchFollows().first, {'team:guest'});
      },
    );

    test('offline sign out returns immediately', () async {
      final value = await _service();
      await value.service.signIn('user@example.com', 'password-test');
      final never = Completer<void>();
      value.http.routes['/auth/v1/logout'] = (_) async {
        await never.future;
        return null;
      };
      await value.service.signOut().timeout(const Duration(seconds: 1));
      expect(value.service.authenticated, isFalse);
      expect(value.service.renewal, isNull);
    });

    test(
      'logout is session-scoped and never revokes the next session',
      () async {
        final value = await _service();
        await value.service.signIn('user@example.com', 'password-test');
        final gate = value.http.hold('/auth/v1/logout');
        await value.service.signOut();
        final signingIn = value.service.signIn(
          'user@example.com',
          'password-test',
        );
        await value.http.waitFor('/auth/v1/logout');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(value.http.count('grant_type=password'), 1);

        gate.complete();
        await signingIn;
        expect(value.http.count('grant_type=password'), 2);
        final logout = value.http.calls.lastWhere(
          (c) => c.path.contains('/auth/v1/logout'),
        );
        expect(logout.path, contains('scope=local'));

        value.http.now = value.http.now.add(const Duration(minutes: 58));
        await value.service.resume();
        expect(value.http.count('grant_type=refresh_token'), 1);
        expect(value.service.authenticated, isTrue);
      },
    );

    test(
      'a late device unregistration never lands after the next sign-in',
      () async {
        final value = await _service();
        await value.service.signIn('user@example.com', 'password-test');
        value.service
          ..enabled = true
          ..token = 'device-token';
        final gate = value.http.hold('futbeat_register_push');
        await value.service.signOut();
        final signingIn = value.service.signIn(
          'user@example.com',
          'password-test',
        );
        await value.http.waitFor('futbeat_register_push');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(value.http.count('grant_type=password'), 1);
        final unregister = value.http.calls.firstWhere(
          (c) => c.path.endsWith('futbeat_register_push'),
        );
        expect((unregister.data as Map)['p_enabled'], isFalse);

        gate.complete();
        await signingIn;
        expect(value.http.count('grant_type=password'), 2);
        expect(value.service.authenticated, isTrue);
      },
    );

    test('a hanging sign-out cleanup is cancelled at its timeout', () async {
      final value = await _service(
        cleanupTimeout: const Duration(milliseconds: 50),
      );
      await value.service.signIn('user@example.com', 'password-test');
      value.http.hold('/auth/v1/logout');
      await value.service.signOut();
      await value.service.signOutCleanup.timeout(const Duration(seconds: 1));
      await value.service
          .signIn('user@example.com', 'password-test')
          .timeout(const Duration(seconds: 1));
      expect(value.service.authenticated, isTrue);
    });

    test(
      'sign out during an in-flight restore refresh stays signed out',
      () async {
        final value = await _stored(server: {'team:a'});
        final gate = value.http.hold('grant_type=refresh_token');
        final restoring = value.service.restore();
        await value.http.waitFor('grant_type=refresh_token');
        expect(value.service.authenticated, isTrue);

        await value.service.signOut();
        gate.complete();
        await restoring;
        await _settle(value.service);

        expect(value.service.authenticated, isFalse);
        expect(value.service.renewal, isNull);
        expect(await _read('futbeat.push.session'), isNull);
        expect(value.http.called('futbeat_read_user_profile'), isFalse);
        expect(value.http.pushes, isEmpty);
      },
    );

    test(
      'sign out during an in-flight resume refresh stays signed out',
      () async {
        final value = await _service(server: {'team:a'});
        await value.service.signIn('user@example.com', 'password-test');
        value.http.now = value.http.now.add(const Duration(minutes: 58));
        final gate = value.http.hold('grant_type=refresh_token');
        final resuming = value.service.resume();
        await value.http.waitFor('grant_type=refresh_token');

        await value.service.signOut();
        gate.complete();
        await resuming;
        await _settle(value.service);

        expect(value.service.authenticated, isFalse);
        expect(await _read('futbeat.push.session'), isNull);
      },
    );
  });

  group('restore', () {
    test(
      'keeps the stored session on a network error, then recovers',
      () async {
        final value = await _stored(server: {'team:a'});
        final stored = await _read('futbeat.push.session');
        final refresh = value.http.routes['grant_type=refresh_token']!;
        final read = value.http.routes['futbeat_read_user_profile']!;
        value.http.routes['grant_type=refresh_token'] = (_) =>
            const _Fail.offline();
        value.http.routes['futbeat_read_user_profile'] = (_) =>
            const _Fail(503);

        await value.service.restore();

        expect(value.service.authenticated, isTrue);
        expect(await _read('futbeat.push.session'), stored);
        expect(value.service.renewal, isNotNull, reason: 'retry is scheduled');
        expect(value.http.pushes, isEmpty, reason: 'no push before a merge');

        // Back online: resume merges; it refreshes once the token is close
        // to expiry.
        value.http.routes['grant_type=refresh_token'] = refresh;
        value.http.routes['futbeat_read_user_profile'] = read;
        await value.service.resume();
        expect(await value.db.watchFollows().first, {'team:a'});
        expect(value.http.count('grant_type=refresh_token'), 1);
        value.http.now = value.http.now.add(const Duration(minutes: 57));
        await value.service.resume();
        expect(value.http.count('grant_type=refresh_token'), 2);
        expect(await _read('futbeat.push.session'), isNot(stored));
      },
    );

    for (final (status, code) in [
      (400, 'refresh_token_not_found'),
      (401, null),
      (403, 'refresh_token_already_used'),
    ]) {
      test(
        'drops the session when GoTrue rejects the refresh ($status)',
        () async {
          final value = await _stored(local: {'team:guest'});
          value.http.routes['grant_type=refresh_token'] = (_) =>
              _Fail(status, {'error_code': ?code});

          await value.service.restore();

          expect(value.service.authenticated, isFalse);
          expect(value.service.renewal, isNull);
          expect(await _read('futbeat.push.session'), isNull);
          expect(await value.db.watchFollows().first, {'team:guest'});
        },
      );
    }

    test(
      'a 403 from a proxy without a GoTrue code keeps the session',
      () async {
        final value = await _stored();
        value.http.routes['grant_type=refresh_token'] = (_) => const _Fail(403);
        await value.service.restore();
        expect(value.service.authenticated, isTrue);
        expect(await _read('futbeat.push.session'), isNotNull);
      },
    );

    test('an invalid 200 refresh body keeps the session', () async {
      final value = await _stored();
      final stored = await _read('futbeat.push.session');
      value.http.routes['grant_type=refresh_token'] = (_) => {
        'access_token': 'only-access',
      };
      await value.service.restore();
      expect(value.service.authenticated, isTrue);
      expect(await _read('futbeat.push.session'), stored);
      expect(value.service.session?['refresh_token'], isNot(isEmpty));
    });

    test('concurrent restore and resume share one refresh', () async {
      final value = await _stored(expiresIn: const Duration(minutes: 1));
      final gate = value.http.hold('grant_type=refresh_token');
      final restoring = value.service.restore();
      await value.http.waitFor('grant_type=refresh_token');
      final resuming = value.service.resume();
      gate.complete();
      await Future.wait([restoring, resuming]);
      await _settle(value.service);

      expect(value.http.count('grant_type=refresh_token'), 1);
      expect(value.service.authenticated, isTrue);
    });
  });

  test('sign in with an invalid 200 body creates no session', () async {
    final value = await _service();
    value.http.routes['grant_type=password'] = (_) => {'user': {}};
    await expectLater(
      value.service.signIn('user@example.com', 'password-test'),
      throwsA(isA<DioException>()),
    );
    expect(value.service.authenticated, isFalse);
    expect(await _read('futbeat.push.session'), isNull);
  });

  test('sign up with an autoconfirm session signs in directly', () async {
    final value = await _service();
    value.http.routes['/auth/v1/signup'] = (_) => value.http.issue('user-a');

    await value.service.signUp(' user@example.com ', 'password-test');

    expect(value.service.authenticated, isTrue);
    expect(value.service.pendingConfirmationEmail, isNull);
    expect(value.service.renewal, isNotNull);
    final stored = jsonDecode((await _read('futbeat.push.session'))!);
    expect(stored['access_token'], startsWith('access-user-a-'));
    expect(value.http.called('futbeat_read_user_profile'), isTrue);
  });

  test('accountChanges follows sign in, refresh and sign out', () async {
    final value = await _service();
    value.http.routes['/auth/v1/signup'] = (_) => value.http.issue('user-a');
    final seen = <String?>[];
    final subscription = value.service.accountChanges.listen(seen.add);
    addTearDown(subscription.cancel);
    expect(value.service.accountId, isNull);

    await value.service.signUp('user@example.com', 'password-test');
    await _settle(value.service);
    expect(value.service.accountId, 'user-a');

    await value.service.signOut();
    await Future<void>.delayed(Duration.zero);
    // A token refresh of the same account emits nothing.
    expect(seen, ['user-a', null]);
    expect(value.service.accountId, isNull);
  });

  test('accountChanges reports a restored session', () async {
    final value = await _stored();
    final seen = <String?>[];
    final subscription = value.service.accountChanges.listen(seen.add);
    addTearDown(subscription.cancel);
    await value.service.restore();
    await Future<void>.delayed(Duration.zero);
    expect(seen, ['user-a']);
  });

  group('password recovery', () {
    test('asks Supabase for a code without signing in', () async {
      final value = await _service();
      await value.service.requestPasswordReset(' user@example.com ');
      final call = value.http.calls.singleWhere(
        (c) => c.path.contains('/auth/v1/recover'),
      );
      expect(call.data, {'email': 'user@example.com'});
      expect(call.headers['Authorization'], isNull);
      expect(value.service.authenticated, isFalse);
    });

    test('a valid code signs in and sets the new password', () async {
      final value = await _service(server: {'team:a'});
      value.http.routes['/auth/v1/verify'] = (_) => value.http.issue('user-a');
      value.http.routes['/auth/v1/user'] = (_) => {'id': 'user-a'};

      await value.service.resetPassword(
        'user@example.com',
        ' 123456 ',
        'nueva-clave-8',
      );

      final verify = value.http.calls.singleWhere(
        (c) => c.path.contains('/auth/v1/verify'),
      );
      expect(verify.data, {
        'type': 'recovery',
        'email': 'user@example.com',
        'token': '123456',
      });
      final update = value.http.calls.singleWhere(
        (c) => c.path.contains('/auth/v1/user'),
      );
      expect(update.method, 'PUT');
      expect(update.data, {'password': 'nueva-clave-8'});
      expect(
        update.headers['Authorization'],
        startsWith('Bearer access-user-a-'),
      );
      expect(value.service.accountId, 'user-a');
      expect(await _read('futbeat.push.session'), isNotNull);
      // Same account sync as a normal sign-in: server follows merge in.
      await _settle(value.service);
      expect(await value.db.watchFollows().first, contains('team:a'));
    });

    test('an invalid or expired code: clear message, no session', () async {
      final value = await _service();
      value.http.routes['/auth/v1/verify'] = (_) => const _Fail(403, {
        'error_code': 'otp_expired',
        'msg': 'Token has expired or is invalid',
      });
      Object? error;
      try {
        await value.service.resetPassword(
          'user@example.com',
          '000000',
          'x' * 8,
        );
      } catch (caught) {
        error = caught;
      }
      expect(error, isA<DioException>());
      expect(authErrorMessage(error!), 'El código no es válido o ya venció.');
      expect(value.service.authenticated, isFalse);
      expect(value.http.called('/auth/v1/user'), isFalse);
    });
  });

  testWidgets('recovery sheet: email, then code and new password', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final db = AppDatabase(NativeDatabase.memory());
    final service = _ResetService(db);
    addTearDown(() async {
      service.dispose();
      await db.close();
    });
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showModalBottomSheet<bool>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => PasswordResetSheet(
                    service: service,
                    initialEmail: 'user@example.com',
                  ),
                );
              },
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reset-code')), findsNothing);

    await tester.tap(find.text('Enviar código'));
    await tester.pumpAndSettle();
    expect(service.requested, ['user@example.com']);
    expect(find.text('Te enviamos un código a tu correo.'), findsOneWidget);

    // Local validation first: no request with a bad code / short password.
    await tester.enterText(find.byKey(const ValueKey('reset-code')), '12');
    await tester.enterText(find.byKey(const ValueKey('reset-password')), 'x');
    await tester.tap(find.text('Cambiar contraseña'));
    await tester.pumpAndSettle();
    expect(find.text('Escribe el código del correo.'), findsOneWidget);
    expect(service.resets, isEmpty);

    // A rejected code shows the clear message and keeps the sheet open.
    service.failNext = true;
    await tester.enterText(find.byKey(const ValueKey('reset-code')), '000000');
    await tester.enterText(
      find.byKey(const ValueKey('reset-password')),
      'nueva-clave-8',
    );
    await tester.tap(find.text('Cambiar contraseña'));
    await tester.pumpAndSettle();
    expect(find.text('El código no es válido o ya venció.'), findsOneWidget);
    expect(result, isNull);

    await tester.enterText(find.byKey(const ValueKey('reset-code')), '123456');
    await tester.tap(find.text('Cambiar contraseña'));
    await tester.pumpAndSettle();
    expect(service.resets.last, (
      'user@example.com',
      '123456',
      'nueva-clave-8',
    ));
    expect(result, isTrue);
    expect(find.byType(PasswordResetSheet), findsNothing);
  });

  test(
    'sign up without a session keeps the pending confirmation flow',
    () async {
      final value = await _service();
      value.http.routes['/auth/v1/signup'] = (_) => {'id': 'user-a'};
      await value.service.signUp('new@example.com', 'password-test');
      expect(value.service.authenticated, isFalse);
      expect(value.service.pendingConfirmationEmail, 'new@example.com');
      expect(await _read('futbeat.push.session'), isNull);
    },
  );

  group('follow merge', () {
    test('first login unions server and local follows', () async {
      final value = await _service(
        server: {'team:a', 'team:b'},
        local: {'team:b', 'team:c'},
      );

      await value.service.signIn('user@example.com', 'password-test');
      await _settle(value.service);

      final union = {'team:a', 'team:b', 'team:c'};
      expect(await value.db.watchFollows().first, union);
      expect(value.http.server['user-a'], union);
      expect(value.http.pushes.every((p) => p.containsAll(union)), isTrue);
      expect(
        (jsonDecode((await _read(PushService.pushedKey('user-a')))!) as List)
            .toSet(),
        union,
      );
      expect(await _read(PushService.lastUserKey), isNull);
    });

    test('an empty local set never wipes server follows', () async {
      final value = await _service(server: {'team:a', 'team:b'});
      await value.service.signIn('user@example.com', 'password-test');
      await _settle(value.service);
      expect(await value.db.watchFollows().first, {'team:a', 'team:b'});
      expect(value.http.pushes, isNotEmpty);
      expect(value.http.pushes.any((push) => push.isEmpty), isFalse);
    });

    test('an offline first reconcile never pushes until the merge', () async {
      final value = await _service(server: {'team:a'}, local: {'team:b'});
      final read = value.http.routes['futbeat_read_user_profile']!;
      value.http.routes['futbeat_read_user_profile'] = (_) =>
          const _Fail.offline();

      await value.service.signIn('user@example.com', 'password-test');
      await value.db.addFollows({'team:c'});
      await _settle(value.service);

      expect(value.service.authenticated, isTrue);
      expect(value.http.pushes, isEmpty);

      value.http.routes['futbeat_read_user_profile'] = read;
      await value.service.resume();
      await _settle(value.service);
      final all = {'team:a', 'team:b', 'team:c'};
      expect(await value.db.watchFollows().first, all);
      expect(value.http.server['user-a'], all);
    });

    test('same user after sign-out unions again (no stale replace)', () async {
      final value = await _service(server: {'team:a', 'team:b'});
      await value.service.signIn('user@example.com', 'password-test');
      await _settle(value.service);
      await value.service.signOut();

      // As a guest the user unfollows team:a and follows team:g.
      await value.db.toggle('team', 'a');
      await value.db.addFollows({'team:g'});
      await value.service.signIn('user@example.com', 'password-test');
      await _settle(value.service);

      final all = {'team:a', 'team:b', 'team:g'};
      expect(await value.db.watchFollows().first, all);
      expect(value.http.server['user-a'], all);
    });

    test(
      'a second account on the same device never inherits follows',
      () async {
        final value = await _service(local: {'team:guest'});
        value.http.server['user-a'] = {'team:a'};
        value.http.server['user-b'] = {'team:b'};

        await value.service.signIn('user@example.com', 'password-test');
        await _settle(value.service);
        expect(value.http.server['user-a'], {'team:a', 'team:guest'});
        await value.service.signOut();

        await value.service.signIn('b@example.com', 'password-test');
        await _settle(value.service);
        expect(await value.db.watchFollows().first, {'team:b'});
        expect(value.http.server['user-b'], {'team:b'});
        await value.service.signOut();

        await value.service.signIn('user@example.com', 'password-test');
        await _settle(value.service);
        expect(await value.db.watchFollows().first, {'team:a', 'team:guest'});
        expect(value.http.server['user-a'], {'team:a', 'team:guest'});
        expect(value.http.server['user-b'], {'team:b'});
      },
    );

    test('follows added on another device survive and are pulled in', () async {
      final value = await _service(server: {'team:a'});
      await value.service.signIn('user@example.com', 'password-test');
      await _settle(value.service);

      // Device B adds team:x; this device then follows team:c.
      value.http.server['user-a']!.add('team:x');
      await value.db.addFollows({'team:c'});
      await _settle(value.service);
      expect(value.http.server['user-a'], {'team:a', 'team:c', 'team:x'});
      expect(await value.db.watchFollows().first, {
        'team:a',
        'team:c',
        'team:x',
      });

      // Device B adds team:y; this device resumes later.
      value.http.server['user-a']!.add('team:y');
      value.http.now = value.http.now.add(const Duration(minutes: 6));
      await value.service.resume();
      await _settle(value.service);
      expect(await value.db.watchFollows().first, contains('team:y'));
      expect(value.http.server['user-a'], contains('team:y'));
    });

    test('unfollowing everything offline is not resurrected', () async {
      final value = await _service(server: {'team:a', 'team:b'});
      await value.service.signIn('user@example.com', 'password-test');
      await _settle(value.service);

      final sync = value.http.routes['futbeat_sync_push_follows']!;
      value.http.routes['futbeat_sync_push_follows'] = (_) =>
          const _Fail.offline();
      await value.db.toggle('team', 'a');
      await value.db.toggle('team', 'b');
      await _settle(value.service);
      expect(value.http.server['user-a'], {'team:a', 'team:b'});

      value.http.routes['futbeat_sync_push_follows'] = sync;
      value.http.now = value.http.now.add(const Duration(minutes: 6));
      await value.service.resume();
      await _settle(value.service);
      expect(await value.db.watchFollows().first, isEmpty);
      expect(value.http.server['user-a'], isEmpty);
    });

    test(
      'a new account keeps guest follows added after another sign-out',
      () async {
        final value = await _service();
        value.http.server['user-a'] = {'team:a'};
        await value.service.signIn('user@example.com', 'password-test');
        await _settle(value.service);
        await value.service.signOut();

        // Weeks of guest use, then a brand-new account with no follows.
        await value.db.addFollows({'team:g'});
        await value.service.signIn('c@example.com', 'password-test');
        await _settle(value.service);

        expect(await value.db.watchFollows().first, {'team:g'});
        expect(value.http.server['user-c'], {'team:g'});
        expect(value.http.server['user-a'], {'team:a'});
        expect(await _read(PushService.leftoverKey), isNull);
      },
    );

    test(
      'a new account with server follows unions them with guest additions',
      () async {
        final value = await _service();
        value.http.server['user-a'] = {'team:a'};
        value.http.server['user-b'] = {'team:b'};
        await value.service.signIn('user@example.com', 'password-test');
        await _settle(value.service);
        await value.service.signOut();
        await value.db.addFollows({'team:g'});

        await value.service.signIn('b@example.com', 'password-test');
        await _settle(value.service);

        expect(await value.db.watchFollows().first, {'team:b', 'team:g'});
        expect(value.http.server['user-b'], {'team:b', 'team:g'});
        expect(value.http.server['user-a'], {'team:a'});
      },
    );

    test('startup restore and resume run a single reconcile', () async {
      final value = await _stored(
        server: {'team:a'},
        expiresIn: const Duration(minutes: 1),
      );
      final gate = value.http.hold('grant_type=refresh_token');
      final restoring = value.service.restore();
      await value.http.waitFor('grant_type=refresh_token');
      final resuming = value.service.resume();
      gate.complete();
      await Future.wait([restoring, resuming]);
      await _settle(value.service);

      expect(value.http.count('futbeat_read_user_profile'), 1);
      expect(await value.db.watchFollows().first, {'team:a'});
    });
  });

  testWidgets('guest profile shows the guest card', (tester) async {
    final value = await _service();
    await _pumpProfile(tester, value.service, value.db);
    await _scrollTo(tester, find.text('Invitado'));
    expect(find.text('Invitado'), findsOneWidget);
    expect(
      find.text('Tus favoritos se guardan en este dispositivo.'),
      findsOneWidget,
    );
    expect(find.text('Correo verificado'), findsNothing);
  });

  testWidgets('signed-in profile shows email and verification badge', (
    tester,
  ) async {
    final value = await _service();
    value.service.session = _session();
    await _pumpProfile(tester, value.service, value.db);
    await _scrollTo(tester, find.text('Correo verificado'));
    expect(find.text('Correo verificado'), findsOneWidget);
    expect(find.text('Invitado'), findsNothing);
    expect(find.text('user@example.com'), findsWidgets);
  });

  testWidgets('unverified account shows the confirm badge and resend', (
    tester,
  ) async {
    final value = await _service();
    value.service.session = {
      'access_token': 'a',
      'user': {'id': 'user-a', 'email': 'a@b.test', 'email_confirmed_at': null},
    };
    await _pumpProfile(tester, value.service, value.db);
    await _scrollTo(tester, find.text('Confirma tu correo'));
    expect(find.text('Confirma tu correo'), findsOneWidget);
    expect(find.text('Reenviar correo'), findsOneWidget);
  });

  testWidgets('invalid input is caught before any request', (tester) async {
    final value = await _service();
    await _pumpProfile(tester, value.service, value.db);
    await _scrollTo(tester, find.text('Crear cuenta'));
    await tester.enterText(find.widgetWithText(TextField, 'Correo'), 'bad');
    await tester.enterText(find.widgetWithText(TextField, 'Contraseña'), '123');
    await tester.tap(find.text('Crear cuenta'));
    await tester.pump();
    expect(find.text('Escribe un correo válido.'), findsOneWidget);
    expect(find.text('Mínimo 8 caracteres.'), findsOneWidget);
    expect(value.http.called('/auth/v1/signup'), isFalse);
  });

  testWidgets('a rejected sign in shows a clear message', (tester) async {
    final value = await _service();
    value.http.routes['grant_type=password'] = (_) => const _Fail(400, {
      'error_code': 'invalid_credentials',
      'msg': 'Invalid login credentials',
    });
    await _pumpProfile(tester, value.service, value.db);
    await _scrollTo(tester, find.text('Crear cuenta'));
    await tester.enterText(
      find.widgetWithText(TextField, 'Correo'),
      'user@example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Contraseña'),
      'wrong-password',
    );
    await tester.tap(find.text('Iniciar sesión'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await _scrollTo(tester, find.text('Correo o contraseña incorrectos.'));
    expect(find.text('Correo o contraseña incorrectos.'), findsOneWidget);
    expect(value.service.authenticated, isFalse);
  });
}

/// PushService whose recovery calls are recorded (UI tests of the sheet).
class _ResetService extends PushService {
  _ResetService(AppDatabase db)
    : super(
        const LiveRealtimeConfig(
          supabaseUrl: 'https://supabase.test',
          publicKey: 'publishable-test-key',
        ),
        db,
        _Tokens(),
      );

  final requested = <String>[];
  final resets = <(String, String, String)>[];
  bool failNext = false;

  @override
  Future<void> requestPasswordReset(String emailAddress) async =>
      requested.add(emailAddress.trim());

  @override
  Future<void> resetPassword(
    String emailAddress,
    String code,
    String newPassword,
  ) async {
    if (failNext) {
      failNext = false;
      final options = RequestOptions(path: '/auth/v1/verify');
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: options,
          statusCode: 403,
          data: {'error_code': 'otp_expired'},
        ),
      );
    }
    resets.add((emailAddress.trim(), code, newPassword));
  }
}

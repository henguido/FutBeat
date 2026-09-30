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

const _user = {
  'id': 'user-a',
  'email': 'user@example.com',
  'email_confirmed_at': '2026-09-27T00:00:00Z',
};

Map<String, dynamic> _session([String access = 'access-test']) => {
  'access_token': access,
  'refresh_token': 'refresh-test',
  'user': _user,
};

/// Fake GoTrue/PostgREST: each route suffix maps to response data or a
/// [_Fail]. Unlisted routes answer 200 with an empty object.
class _Http {
  _Http() {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          calls.add(options);
          final route = routes.entries
              .where((entry) => options.path.contains(entry.key))
              .map((entry) => entry.value)
              .firstOrNull;
          final result = route == null ? <String, dynamic>{} : route();
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
  }

  final dio = Dio();
  final calls = <RequestOptions>[];
  final routes = <String, Object? Function()>{
    'grant_type=password': _session,
    'grant_type=refresh_token': () => _session('access-refreshed'),
  };
  Set<String> serverFollows = {};

  void serveProfile() {
    routes['futbeat_read_user_profile'] = () => {
      'preferences': <String, dynamic>{},
      'follows': [
        for (final key in serverFollows)
          {'type': key.split(':').first, 'id': key.split(':').last},
      ],
    };
  }

  List<Set<String>> get pushes => [
    for (final call in calls)
      if (call.path.endsWith('futbeat_sync_push_follows'))
        {
          for (final item in (call.data as Map)['p_follows'] as List)
            '${item['type']}:${item['id']}',
        },
  ];

  bool called(String suffix) => calls.any((c) => c.path.contains(suffix));
}

Future<({PushService service, AppDatabase db, _Http http})> _service({
  Map<String, String> storage = const {},
  Set<String> local = const {},
  Set<String> server = const {},
}) async {
  FlutterSecureStorage.setMockInitialValues(Map.of(storage));
  final db = AppDatabase(NativeDatabase.memory());
  await db.addFollows(local);
  final http = _Http()..serverFollows = server;
  http.serveProfile();
  final service = PushService(
    const LiveRealtimeConfig(
      supabaseUrl: 'https://supabase.test',
      publicKey: 'publishable-test-key',
    ),
    db,
    _Tokens(),
    dio: http.dio,
  );
  addTearDown(() async {
    service.dispose();
    await db.close();
  });
  return (service: service, db: db, http: http);
}

Future<String?> _stored(String key) =>
    const FlutterSecureStorage().read(key: key);

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

  test(
    'sign out with a failing logout still clears the session and keeps follows',
    () async {
      final value = await _service(local: {'team:guest'});
      await value.service.signIn('user@example.com', 'password-test');
      value.http.routes['/auth/v1/logout'] = () => const _Fail.offline();

      await value.service.signOut();

      expect(value.http.called('/auth/v1/logout'), isTrue);
      expect(value.service.authenticated, isFalse);
      expect(value.service.renewal, isNull);
      expect(value.service.follows, isNull);
      expect(await _stored('futbeat.push.session'), isNull);
      expect(await value.db.watchFollows().first, {'team:guest'});
    },
  );

  test('restore keeps the stored session on a network error', () async {
    final stored = jsonEncode(_session('access-old'));
    final value = await _service(storage: {'futbeat.push.session': stored});
    value.http.routes['grant_type=refresh_token'] = () => const _Fail.offline();
    value.http.routes['futbeat_read_user_profile'] = () => const _Fail(503);

    await value.service.restore();

    expect(value.service.authenticated, isTrue);
    expect(value.service.session?['access_token'], 'access-old');
    expect(await _stored('futbeat.push.session'), stored);
    expect(value.service.renewal, isNotNull, reason: 'retry is scheduled');
    expect(value.http.pushes, isEmpty, reason: 'no push before a merge');

    // Back online: the resume retry refreshes and merges.
    value.http.routes['grant_type=refresh_token'] = () =>
        _session('access-refreshed');
    value.http.serveProfile();
    await value.service.resume();
    expect(value.service.session?['access_token'], 'access-refreshed');
    expect(value.http.pushes, isNotEmpty);
  });

  for (final status in [400, 401, 403]) {
    test(
      'restore drops the session when the refresh token is rejected ($status)',
      () async {
        final value = await _service(
          storage: {'futbeat.push.session': jsonEncode(_session())},
          local: {'team:guest'},
        );
        value.http.routes['grant_type=refresh_token'] = () =>
            _Fail(status, {'error_code': 'refresh_token_not_found'});

        await value.service.restore();

        expect(value.service.authenticated, isFalse);
        expect(value.service.renewal, isNull);
        expect(await _stored('futbeat.push.session'), isNull);
        expect(await value.db.watchFollows().first, {'team:guest'});
      },
    );
  }

  test('sign up with an autoconfirm session signs in directly', () async {
    final value = await _service();
    value.http.routes['/auth/v1/signup'] = () => _session('access-signup');

    await value.service.signUp(' user@example.com ', 'password-test');

    expect(value.service.authenticated, isTrue);
    expect(value.service.pendingConfirmationEmail, isNull);
    expect(value.service.renewal, isNotNull);
    final stored = jsonDecode((await _stored('futbeat.push.session'))!);
    expect(stored['access_token'], 'access-signup');
    expect(value.http.called('futbeat_read_user_profile'), isTrue);
  });

  test(
    'sign up without a session keeps the pending confirmation flow',
    () async {
      final value = await _service();
      value.http.routes['/auth/v1/signup'] = () => {'id': 'user-a'};
      await value.service.signUp('new@example.com', 'password-test');
      expect(value.service.authenticated, isFalse);
      expect(value.service.pendingConfirmationEmail, 'new@example.com');
      expect(await _stored('futbeat.push.session'), isNull);
    },
  );

  test(
    'first login merges server and local follows and pushes the union',
    () async {
      final value = await _service(
        server: {'team:a', 'team:b'},
        local: {'team:b', 'team:c'},
      );

      await value.service.signIn('user@example.com', 'password-test');
      await value.service.pending;

      final union = {'team:a', 'team:b', 'team:c'};
      expect(await value.db.watchFollows().first, union);
      expect(value.http.pushes, isNotEmpty);
      expect(
        value.http.pushes.every((push) => push.containsAll(union)),
        isTrue,
      );
      expect(await _stored(PushService.linkedFlagKey('user-a')), 'true');
    },
  );

  test('an empty local set never wipes server follows on first link', () async {
    final value = await _service(server: {'team:a', 'team:b'});

    await value.service.signIn('user@example.com', 'password-test');
    await value.service.pending;

    expect(await value.db.watchFollows().first, {'team:a', 'team:b'});
    expect(value.http.pushes, isNotEmpty);
    expect(value.http.pushes.any((push) => push.isEmpty), isFalse);
  });

  test(
    'an offline first reconcile never pushes until the merge succeeds',
    () async {
      final value = await _service(server: {'team:a'}, local: {'team:b'});
      value.http.routes['futbeat_read_user_profile'] = () =>
          const _Fail.offline();

      await value.service.signIn('user@example.com', 'password-test');
      await value.db.addFollows({'team:c'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await value.service.pending;

      expect(value.service.authenticated, isTrue);
      expect(value.http.pushes, isEmpty);

      value.http.serveProfile();
      await value.service.resume();
      expect(await value.db.watchFollows().first, {
        'team:a',
        'team:b',
        'team:c',
      });
      expect(value.http.pushes.last, {'team:a', 'team:b', 'team:c'});
    },
  );

  test('the linked flag makes the union merge run once per user', () async {
    final value = await _service(
      server: {'team:a', 'team:b'},
      local: {'team:c'},
    );
    await value.service.signIn('user@example.com', 'password-test');
    expect(await value.db.watchFollows().first, {'team:a', 'team:b', 'team:c'});

    // The user unfollows team:a on this device, then signs in again while
    // the server still has the old set: local stays the source of truth.
    await value.service.signOut();
    await value.db.toggle('team', 'a');
    value.http.calls.clear();
    await value.service.signIn('user@example.com', 'password-test');
    await value.service.pending;

    expect(await value.db.watchFollows().first, {'team:b', 'team:c'});
    expect(value.http.pushes.last, {'team:b', 'team:c'});
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
    value.http.routes['grant_type=password'] = () => const _Fail(400, {
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

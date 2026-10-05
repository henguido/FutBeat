import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/push.dart';
import 'package:futbeat/features/auth/auth_sheet.dart';

const _config = LiveRealtimeConfig(
  supabaseUrl: 'https://supabase.test',
  publicKey: 'publishable-test-key',
);

class _Tokens implements PushTokenSource {
  @override
  Future<String?> requestToken() async => null;

  @override
  Stream<String> get rotations => const Stream.empty();
}

Map<String, dynamic> _session([String provider = 'email']) => {
  'access_token': 'access',
  'refresh_token': 'refresh',
  'user': {
    'id': 'user-a',
    'email': 'user@example.com',
    'email_confirmed_at': '2026-10-04T00:00:00Z',
    'app_metadata': {'provider': provider},
  },
};

/// GoTrue fake: `/settings` and the PKCE token exchange; every other
/// account call answers empty.
class _GoTrue {
  _GoTrue({this.external = const {'google': true, 'facebook': true}}) {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          calls.add(options);
          Object? data = <String, dynamic>{};
          if (options.path.endsWith('/auth/v1/settings')) {
            data = {'external': external};
          } else if (options.path.contains('grant_type=pkce')) {
            data = _session('google');
          }
          handler.resolve(
            Response(requestOptions: options, statusCode: 200, data: data),
          );
        },
      ),
    );
  }

  final Map<String, bool> external;
  final dio = Dio();
  final calls = <RequestOptions>[];

  List<RequestOptions> called(String path) => [
    for (final call in calls)
      if (call.path.contains(path)) call,
  ];
}

void main() {
  late AppDatabase db;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  PushService service(
    _GoTrue http, {
    bool oauth = true,
    OAuthBrowser? browser,
  }) {
    final value = PushService(
      _config,
      db,
      _Tokens(),
      dio: http.dio,
      oauthEnabled: oauth,
      oauthBrowser: browser,
    );
    addTearDown(value.dispose);
    return value;
  }

  group('OAuth providers', () {
    test(
      'a build without social sign-in offers none and asks nothing',
      () async {
        final http = _GoTrue();
        expect(await service(http, oauth: false).oauthProviders(), isEmpty);
        expect(http.calls, isEmpty);
      },
    );

    test('only providers enabled in Supabase are offered', () async {
      final http = _GoTrue(external: {'google': true, 'facebook': false});
      expect(await service(http).oauthProviders(), {OAuthProvider.google});
    });
  });

  group('PKCE sign-in', () {
    test('code exchange with the verifier of the challenge signs in', () async {
      Uri? opened;
      final http = _GoTrue();
      final value = service(
        http,
        browser: (url, scheme) async {
          opened = url;
          expect(scheme, 'com.futbeat.futbeat');
          return 'com.futbeat.futbeat://login-callback?code=one-time';
        },
      );
      await value.signInWithOAuth(OAuthProvider.google);

      final params = opened!.queryParameters;
      expect(opened!.path, '/auth/v1/authorize');
      expect(params['provider'], 'google');
      expect(params['redirect_to'], 'com.futbeat.futbeat://login-callback');
      expect(params['code_challenge_method'], 's256');
      final exchange = http.called('grant_type=pkce').single;
      final body = exchange.data as Map;
      expect(body['auth_code'], 'one-time');
      final verifier = body['code_verifier'] as String;
      expect(
        params['code_challenge'],
        base64Url
            .encode(sha256.convert(ascii.encode(verifier)).bytes)
            .replaceAll('=', ''),
      );
      expect(value.authenticated, isTrue);
      expect(value.authProvider, 'google');
    });

    test('closing the provider page creates no session', () async {
      final http = _GoTrue();
      final value = service(
        http,
        browser: (_, _) async => throw const OAuthCancelled(),
      );
      await expectLater(
        value.signInWithOAuth(OAuthProvider.facebook),
        throwsA(isA<OAuthCancelled>()),
      );
      expect(http.called('grant_type=pkce'), isEmpty);
      expect(value.authenticated, isFalse);
    });

    test('a denied or failed redirect never signs in', () async {
      for (final (callback, matcher) in [
        (
          'com.futbeat.futbeat://login-callback?error=access_denied',
          isA<OAuthCancelled>(),
        ),
        (
          'com.futbeat.futbeat://login-callback#error=server_error',
          isA<OAuthFailed>(),
        ),
        ('com.futbeat.futbeat://login-callback', isA<OAuthFailed>()),
      ]) {
        final http = _GoTrue();
        final value = service(http, browser: (_, _) async => callback);
        await expectLater(
          value.signInWithOAuth(OAuthProvider.google),
          throwsA(matcher),
          reason: callback,
        );
        expect(http.called('grant_type=pkce'), isEmpty);
        expect(value.authenticated, isFalse);
      }
    });

    test('refused when this build has no social sign-in', () async {
      await expectLater(
        service(_GoTrue(), oauth: false).signInWithOAuth(OAuthProvider.google),
        throwsStateError,
      );
    });
  });

  group('AuthSheet', () {
    Future<bool?> open(
      WidgetTester tester,
      PushService value,
      AuthMode mode, {
      Set<OAuthProvider> providers = const {},
    }) async {
      bool? result;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            pushServiceProvider.overrideWithValue(value),
            oauthProvidersProvider.overrideWith((ref) async => providers),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async =>
                      result = await showAuthSheet(context, mode),
                  child: const Text('abrir'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      return result;
    }

    String title(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const ValueKey('auth-title'))).data!;

    testWidgets('login and signup modes, switchable', (tester) async {
      final value = _FakeAuth(db);
      await open(tester, value, AuthMode.login);
      expect(title(tester), 'Iniciar sesión');
      expect(find.byKey(const ValueKey('auth-forgot')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('auth-switch')));
      await tester.pumpAndSettle();
      expect(title(tester), 'Crear cuenta');
      expect(find.byKey(const ValueKey('auth-forgot')), findsNothing);
    });

    String primary(WidgetTester tester) =>
        (tester
                    .widget<FilledButton>(
                      find.byKey(const ValueKey('auth-submit')),
                    )
                    .child!
                as Text)
            .data!;

    testWidgets('one primary CTA per mode, the other is a link', (
      tester,
    ) async {
      final value = _FakeAuth(db);
      await open(tester, value, AuthMode.login);
      expect(find.byType(FilledButton), findsOneWidget);
      expect(primary(tester), 'Iniciar sesión');
      expect(find.text('¿No tienes cuenta? Crear cuenta'), findsOneWidget);
      expect(find.byKey(const ValueKey('auth-forgot')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('auth-switch')));
      await tester.pumpAndSettle();
      expect(find.byType(FilledButton), findsOneWidget);
      expect(primary(tester), 'Crear cuenta');
      expect(find.text('¿Ya tienes cuenta? Iniciar sesión'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('auth-switch')));
      await tester.pumpAndSettle();
      expect(primary(tester), 'Iniciar sesión');
    });

    testWidgets('an existing address goes to login, keeps the email', (
      tester,
    ) async {
      final value = _FakeAuth(db)..existingAccount = true;
      await open(tester, value, AuthMode.signup);
      await tester.enterText(
        find.byKey(const ValueKey('auth-email')),
        'ya@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('auth-password')),
        'secreta-12',
      );
      await tester.tap(find.byKey(const ValueKey('auth-submit')));
      await tester.pumpAndSettle();
      expect(title(tester), 'Iniciar sesión');
      expect(find.textContaining('ya está registrado'), findsOneWidget);
      expect(find.byKey(const ValueKey('auth-confirmation')), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('auth-email')))
            .controller!
            .text,
        'ya@example.com',
      );
    });

    testWidgets('check-your-email actions: change email and go to login', (
      tester,
    ) async {
      final value = _FakeAuth(db);
      await open(tester, value, AuthMode.signup);
      await tester.enterText(
        find.byKey(const ValueKey('auth-email')),
        'nuevo@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('auth-password')),
        'secreta-12',
      );
      await tester.tap(find.byKey(const ValueKey('auth-submit')));
      await tester.pumpAndSettle();
      expect(find.text('nuevo@example.com'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('auth-change-email')));
      await tester.pumpAndSettle();
      expect(title(tester), 'Crear cuenta');
      expect(find.byKey(const ValueKey('auth-confirmation')), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('auth-password')),
        'secreta-12',
      );
      await tester.tap(find.byKey(const ValueKey('auth-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('auth-confirmation-login')));
      await tester.pumpAndSettle();
      expect(title(tester), 'Iniciar sesión');
    });

    testWidgets('social buttons only for enabled providers', (tester) async {
      final value = _FakeAuth(db);
      await open(tester, value, AuthMode.signup);
      expect(find.byKey(const ValueKey('auth-google')), findsNothing);
      expect(find.byKey(const ValueKey('auth-facebook')), findsNothing);
    });

    testWidgets('enabled providers get their buttons', (tester) async {
      final value = _FakeAuth(db);
      await open(
        tester,
        value,
        AuthMode.signup,
        providers: {OAuthProvider.google, OAuthProvider.facebook},
      );
      expect(find.text('Continuar con Google'), findsOneWidget);
      expect(find.text('Continuar con Facebook'), findsOneWidget);
    });

    testWidgets('email sign-in closes with a session', (tester) async {
      final value = _FakeAuth(db);
      bool? result;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            pushServiceProvider.overrideWithValue(value),
            oauthProvidersProvider.overrideWith((ref) async => const {}),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async =>
                      result = await showAuthSheet(context, AuthMode.login),
                  child: const Text('abrir'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      // Local validation first: no request.
      await tester.tap(find.byKey(const ValueKey('auth-submit')));
      await tester.pumpAndSettle();
      expect(value.signIns, isEmpty);

      await tester.enterText(
        find.byKey(const ValueKey('auth-email')),
        'user@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('auth-password')),
        'secreta-1',
      );
      // Password visibility toggles.
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('auth-password')))
            .obscureText,
        isTrue,
      );
      await tester.tap(find.byTooltip('Mostrar contraseña'));
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('auth-password')))
            .obscureText,
        isFalse,
      );
      await tester.tap(find.byKey(const ValueKey('auth-submit')));
      await tester.pumpAndSettle();
      expect(value.signIns, ['user@example.com']);
      expect(result, isTrue);
      expect(find.byType(AuthSheet), findsNothing);
    });

    testWidgets('a rejected sign-in keeps the sheet open with the reason', (
      tester,
    ) async {
      final value = _FakeAuth(db)..rejectSignIn = 'invalid_credentials';
      await open(tester, value, AuthMode.login);
      await tester.enterText(
        find.byKey(const ValueKey('auth-email')),
        'user@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('auth-password')),
        'equivocada',
      );
      await tester.tap(find.byKey(const ValueKey('auth-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Correo o contraseña incorrectos.'), findsOneWidget);
      expect(find.byType(AuthSheet), findsOneWidget);
      expect(value.authenticated, isFalse);
    });

    testWidgets('unconfirmed email: confirmation card and resend', (
      tester,
    ) async {
      final value = _FakeAuth(db)..rejectSignIn = 'email_not_confirmed';
      await open(tester, value, AuthMode.login);
      await tester.enterText(
        find.byKey(const ValueKey('auth-email')),
        'nuevo@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('auth-password')),
        'secreta-1',
      );
      await tester.tap(find.byKey(const ValueKey('auth-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Revisa tu correo'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('auth-resend')));
      await tester.pumpAndSettle();
      expect(value.resent, ['nuevo@example.com']);
      expect(find.text('Correo de confirmación reenviado.'), findsOneWidget);
    });

    testWidgets('sign-up waiting for confirmation shows no session', (
      tester,
    ) async {
      final value = _FakeAuth(db);
      final result = open(tester, value, AuthMode.signup);
      await result;
      await tester.enterText(
        find.byKey(const ValueKey('auth-email')),
        'nuevo@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('auth-password')),
        'secreta-12',
      );
      await tester.tap(find.byKey(const ValueKey('auth-submit')));
      await tester.pumpAndSettle();
      expect(value.signUps, ['nuevo@example.com']);
      expect(value.authenticated, isFalse);
      expect(find.text('Revisa tu correo'), findsOneWidget);
      expect(find.byType(AuthSheet), findsOneWidget);
    });

    testWidgets('cancelled social sign-in keeps the sheet, no error', (
      tester,
    ) async {
      final value = _FakeAuth(db)..cancelOAuth = true;
      await open(
        tester,
        value,
        AuthMode.login,
        providers: {OAuthProvider.google},
      );
      await tester.tap(find.byKey(const ValueKey('auth-google')));
      await tester.pumpAndSettle();
      expect(value.oauth, [OAuthProvider.google]);
      expect(find.byType(AuthSheet), findsOneWidget);
      expect(find.byKey(const ValueKey('auth-message')), findsNothing);
      expect(value.authenticated, isFalse);
    });

    testWidgets('social sign-in success closes the sheet', (tester) async {
      final value = _FakeAuth(db);
      await open(
        tester,
        value,
        AuthMode.login,
        providers: {OAuthProvider.facebook},
      );
      await tester.tap(find.byKey(const ValueKey('auth-facebook')));
      await tester.pumpAndSettle();
      expect(value.authenticated, isTrue);
      expect(find.byType(AuthSheet), findsNothing);
    });
  });
}

/// Records the calls; sessions are set without a server.
class _FakeAuth extends PushService {
  _FakeAuth(AppDatabase db) : super(_config, db, _Tokens());

  final signIns = <String>[];
  final signUps = <String>[];
  final resent = <String?>[];
  final oauth = <OAuthProvider>[];
  String? rejectSignIn;
  bool cancelOAuth = false;
  bool existingAccount = false;

  @override
  Future<void> signIn(String email, String password) async {
    signIns.add(email.trim());
    final code = rejectSignIn;
    if (code != null) {
      final options = RequestOptions(path: '/auth/v1/token');
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: options,
          statusCode: 400,
          data: {'error_code': code},
        ),
      );
    }
    session = _session();
  }

  @override
  Future<void> signUp(String email, String password) async {
    signUps.add(email.trim());
    if (existingAccount) throw const AccountAlreadyExists();
  }

  @override
  Future<void> resendEmailConfirmation({String? emailAddress}) async =>
      resent.add(emailAddress);

  @override
  Future<void> signInWithOAuth(OAuthProvider provider) async {
    oauth.add(provider);
    if (cancelOAuth) throw const OAuthCancelled();
    session = _session(provider.id);
  }
}

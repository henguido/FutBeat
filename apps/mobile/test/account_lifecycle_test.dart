import 'dart:async';

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
import 'package:futbeat/features/profile/password_recovery_screen.dart';
import 'package:futbeat/features/profile/profile_screen.dart';

class _Tokens implements PushTokenSource {
  @override
  Future<String?> requestToken() async => null;

  @override
  Stream<String> get rotations => const Stream.empty();
}

class _Http {
  _Http({
    this.fail = const {},
    this.pkceGates = const {},
    this.passwordUpdateGate,
    this.onDelete,
  }) {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          calls.add(options);
          if (options.path.endsWith('futbeat-delete-account')) {
            onDelete?.call();
          }
          if (fail.any(options.path.startsWith)) {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response(requestOptions: options, statusCode: 503),
              ),
            );
            return;
          }
          dynamic data = <String, dynamic>{};
          if (options.path.contains('grant_type=password')) {
            data = {
              'access_token': 'access-test',
              'refresh_token': 'refresh-test',
              'user': {
                'id': 'user-a',
                'email': 'user@example.com',
                'email_confirmed_at': '2026-09-27T00:00:00Z',
              },
            };
          } else if (options.path.contains('grant_type=pkce')) {
            final code = options.data['auth_code']?.toString();
            final gate = pkceGates[code];
            if (gate != null) await gate.future;
            data = {'access_token': 'recovery-access-$code'};
          } else if (options.path.endsWith('futbeat_read_user_profile')) {
            data = {'preferences': <String, dynamic>{}, 'follows': <dynamic>[]};
          } else if (options.path.endsWith('futbeat-delete-account')) {
            data = {'deleted': true};
          }
          if (options.method == 'PUT' && passwordUpdateGate != null) {
            await passwordUpdateGate!.future;
          }
          handler.resolve(
            Response(requestOptions: options, statusCode: 200, data: data),
          );
        },
      ),
    );
  }

  final dio = Dio();
  final Set<String> fail;
  final Map<String, Completer<void>> pkceGates;
  final Completer<void>? passwordUpdateGate;
  final void Function()? onDelete;
  final calls = <RequestOptions>[];
}

Future<({PushService service, AppDatabase db, _Http http})> _service({
  Set<String> fail = const {},
  Map<String, Completer<void>> pkceGates = const {},
  Completer<void>? passwordUpdateGate,
  void Function()? onDelete,
}) async {
  FlutterSecureStorage.setMockInitialValues({});
  final db = AppDatabase(NativeDatabase.memory());
  final http = _Http(
    fail: fail,
    pkceGates: pkceGates,
    passwordUpdateGate: passwordUpdateGate,
    onDelete: onDelete,
  );
  final service = PushService(
    const LiveRealtimeConfig(
      supabaseUrl: 'https://supabase.test',
      publicKey: 'publishable-test-key',
    ),
    db,
    _Tokens(),
    dio: http.dio,
  );
  return (service: service, db: db, http: http);
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

void main() {
  test(
    'sign in trims email, persists session, reconciles, and starts sync',
    () async {
      final value = await _service();
      addTearDown(() async {
        value.service.dispose();
        await value.db.close();
      });

      await value.service.signIn('  user@example.com  ', 'password-test');

      final request = value.http.calls.first;
      expect(request.path, contains('grant_type=password'));
      expect(request.data, {
        'email': 'user@example.com',
        'password': 'password-test',
      });
      expect(value.service.authenticated, isTrue);
      expect(value.service.emailVerified, isTrue);
      expect(value.service.renewal, isNotNull);
      expect(
        value.http.calls.any(
          (call) => call.path.endsWith('futbeat_read_user_profile'),
        ),
        isTrue,
      );
    },
  );

  test('sign in failure never creates a local session', () async {
    final value = await _service(
      fail: {'https://supabase.test/auth/v1/token?grant_type=password'},
    );
    addTearDown(() async {
      value.service.dispose();
      await value.db.close();
    });

    await expectLater(
      value.service.signIn('user@example.com', 'password-test'),
      throwsA(isA<DioException>()),
    );
    expect(value.service.authenticated, isFalse);
    expect(value.service.renewal, isNull);
  });

  test(
    'sign up sends the expected request without persisting a fake session',
    () async {
      final value = await _service();
      addTearDown(() async {
        value.service.dispose();
        await value.db.close();
      });
      await value.service.signUp(' new@example.com ', 'password-test');
      expect(value.http.calls.single.data, {
        'email': 'new@example.com',
        'password': 'password-test',
      });
      expect(value.service.authenticated, isFalse);
      expect(value.service.pendingConfirmationEmail, 'new@example.com');
    },
  );

  test('an unconfigured account service degrades without making an account mandatory', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final db = AppDatabase(NativeDatabase.memory());
    final service = PushService(
      const LiveRealtimeConfig(supabaseUrl: '', publicKey: ''),
      db,
      _Tokens(),
    );
    addTearDown(() async {
      service.dispose();
      await db.close();
    });
    expect(service.accountConfigured, isFalse);
    expect(service.authenticated, isFalse);
    await expectLater(
      service.signIn('a@b.test', 'password-test'),
      throwsStateError,
    );
  });

  test(
    'password reset trims email, is neutral, and exposes recoverable failure',
    () async {
      final value = await _service();
      addTearDown(() async {
        value.service.dispose();
        await value.db.close();
      });
      await value.service.requestPasswordReset(' person@example.com ');
      final resetUri = Uri.parse(value.http.calls.single.path);
      expect(resetUri.path, endsWith('/auth/v1/recover'));
      expect(
        resetUri.queryParameters['redirect_to'],
        PushService.passwordRecoveryRedirect,
      );
      expect(value.http.calls.single.data['email'], 'person@example.com');
      expect(value.http.calls.single.data['code_challenge_method'], 's256');
      expect(value.http.calls.single.data['code_challenge'], isNotEmpty);
      await expectLater(
        value.service.requestPasswordReset('  '),
        throwsArgumentError,
      );

      final failed = await _service(
        fail: {'https://supabase.test/auth/v1/recover'},
      );
      addTearDown(() async {
        failed.service.dispose();
        await failed.db.close();
      });
      await expectLater(
        failed.service.requestPasswordReset('a@b.test'),
        throwsA(isA<DioException>()),
      );
    },
  );

  test('pending signup can resend while signed out', () async {
    final value = await _service();
    addTearDown(() async {
      value.service.dispose();
      await value.db.close();
    });
    await value.service.signUp('pending@example.com', 'password-test');
    await value.service.resendEmailConfirmation();
    expect(value.http.calls.last.path, endsWith('/auth/v1/resend'));
    expect(value.http.calls.last.data, {
      'type': 'signup',
      'email': 'pending@example.com',
    });
  });

  test('recovery link updates password with its short-lived token', () async {
    final value = await _service();
    addTearDown(() async {
      value.service.dispose();
      await value.db.close();
    });
    await value.service.requestPasswordReset('person@example.com');
    value.http.calls.clear();
    await value.service.beginPasswordRecovery(
      Uri.parse('futbeat://auth/recovery?code=one-time-code'),
    );
    final exchange = value.http.calls.single;
    expect(exchange.path, contains('grant_type=pkce'));
    expect(exchange.data['auth_code'], 'one-time-code');
    expect(exchange.data['code_verifier'], isNotEmpty);
    value.http.calls.clear();
    await value.service.updateRecoveredPassword('new-password');
    final request = value.http.calls.single;
    expect(request.method, 'PUT');
    expect(request.path, endsWith('/auth/v1/user'));
    expect(request.data, {'password': 'new-password'});
    expect(
      request.headers['Authorization'],
      'Bearer recovery-access-one-time-code',
    );
    expect(value.service.recoveryAccessToken, isNull);
  });

  test(
    'a stale PKCE exchange cannot replace the newest recovery token',
    () async {
      final firstGate = Completer<void>();
      final secondGate = Completer<void>();
      final value = await _service(
        pkceGates: {'first': firstGate, 'second': secondGate},
      );
      addTearDown(() async {
        value.service.dispose();
        await value.db.close();
      });
      await value.service.requestPasswordReset('person@example.com');
      final first = value.service.beginPasswordRecovery(
        Uri.parse('futbeat://auth/recovery?code=first'),
      );
      final second = value.service.beginPasswordRecovery(
        Uri.parse('futbeat://auth/recovery?code=second'),
      );
      secondGate.complete();
      await second;
      firstGate.complete();
      await first;
      expect(value.service.recoveryAccessToken, 'recovery-access-second');
    },
  );

  test(
    'password updates are serialized and the newest recovery wins',
    () async {
      final updateGate = Completer<void>();
      final value = await _service(passwordUpdateGate: updateGate);
      addTearDown(() async {
        value.service.dispose();
        await value.db.close();
      });
      await value.service.requestPasswordReset('person@example.com');
      await value.service.beginPasswordRecovery(
        Uri.parse('futbeat://auth/recovery?code=first'),
      );
      final oldUpdate = value.service.updateRecoveredPassword('old-password');
      await Future<void>.delayed(Duration.zero);
      await value.service.requestPasswordReset('person@example.com');
      await value.service.beginPasswordRecovery(
        Uri.parse('futbeat://auth/recovery?code=second'),
      );
      final newUpdate = value.service.updateRecoveredPassword('new-password');
      await Future<void>.delayed(Duration.zero);
      expect(
        value.http.calls.where((call) => call.method == 'PUT'),
        hasLength(1),
      );
      updateGate.complete();
      await Future.wait([oldUpdate, newUpdate]);
      expect(
        value.http.calls
            .where((call) => call.method == 'PUT')
            .map((call) => call.data),
        [
          {'password': 'old-password'},
          {'password': 'new-password'},
        ],
      );
      expect(value.service.recoveryAccessToken, isNull);
    },
  );

  test(
    'invalid recovery links and short passwords are rejected locally',
    () async {
      final value = await _service();
      addTearDown(() async {
        value.service.dispose();
        await value.db.close();
      });
      await expectLater(
        value.service.beginPasswordRecovery(
          Uri.parse('futbeat://auth/recovery'),
        ),
        throwsStateError,
      );
      await value.service.requestPasswordReset('person@example.com');
      await value.service.beginPasswordRecovery(
        Uri.parse('futbeat://auth/recovery?code=one-time-code'),
      );
      await expectLater(
        value.service.updateRecoveredPassword('short'),
        throwsArgumentError,
      );
    },
  );

  testWidgets('recovery screen completes password update', (tester) async {
    final value = await _service();
    addTearDown(() async {
      value.service.dispose();
      await value.db.close();
    });
    await tester.runAsync(
      () => value.service.requestPasswordReset('person@example.com'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [pushServiceProvider.overrideWithValue(value.service)],
        child: MaterialApp(
          home: PasswordRecoveryScreen(
            uri: Uri.parse('futbeat://auth/recovery?code=screen-code'),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.enterText(find.byType(TextField).at(0), 'new-password');
    await tester.enterText(find.byType(TextField).at(1), 'new-password');
    await tester.tap(find.text('Actualizar contraseña'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      find.text('Contraseña actualizada. Ya puedes iniciar sesión.'),
      findsOneWidget,
    );
  });

  testWidgets('an open recovery screen exchanges a newly received code', (
    tester,
  ) async {
    final value = await _service();
    addTearDown(() async {
      value.service.dispose();
      await value.db.close();
    });
    Future<void> request() => tester.runAsync(
      () => value.service.requestPasswordReset('person@example.com'),
    );
    Widget screen(String code) => ProviderScope(
      overrides: [pushServiceProvider.overrideWithValue(value.service)],
      child: MaterialApp(
        home: PasswordRecoveryScreen(
          uri: Uri.parse('futbeat://auth/recovery?code=$code'),
        ),
      ),
    );

    await request();
    await tester.pumpWidget(screen('first-code'));
    await tester.pump(const Duration(milliseconds: 500));
    await request();
    await tester.pumpWidget(screen('second-code'));
    await tester.pump(const Duration(milliseconds: 500));

    final exchanges = value.http.calls
        .where((call) => call.path.contains('grant_type=pkce'))
        .toList();
    expect(exchanges.map((call) => call.data['auth_code']), [
      'first-code',
      'second-code',
    ]);
  });

  test(
    'email verification distinguishes verified, pending, and absent claims',
    () async {
      final value = await _service();
      addTearDown(() async {
        value.service.dispose();
        await value.db.close();
      });
      value.service.session = {
        'access_token': 'a',
        'user': {'email': 'a@b.test', 'email_confirmed_at': null},
      };
      expect(value.service.emailVerified, isFalse);
      await value.service.resendEmailConfirmation();
      expect(value.http.calls.single.path, endsWith('/auth/v1/resend'));
      expect(value.http.calls.single.data, {
        'type': 'signup',
        'email': 'a@b.test',
      });
      value.service.session = {
        'access_token': 'a',
        'user': {'email': 'a@b.test'},
      };
      expect(value.service.emailVerified, isNull);
      value.service.session = {
        'access_token': 'a',
        'user': {'email': 'a@b.test', 'confirmed_at': 'now'},
      };
      expect(value.service.emailVerified, isTrue);
    },
  );

  test(
    'delete failure keeps session; success clears identity and account timers',
    () async {
      late PushService failedService;
      var quiescedBeforeDelete = false;
      final failed = await _service(
        fail: {'https://supabase.test/functions/v1/futbeat-delete-account'},
        onDelete: () {
          quiescedBeforeDelete =
              failedService.renewal == null &&
              failedService.rotation == null &&
              failedService.follows == null;
        },
      );
      failedService = failed.service;
      addTearDown(() async {
        failed.service.dispose();
        await failed.db.close();
      });
      await failed.service.signIn('user@example.com', 'password-test');
      expect(failed.service.renewal, isNotNull);
      expect(failed.service.follows, isNotNull);
      await expectLater(
        failed.service.deleteAccount(),
        throwsA(isA<DioException>()),
      );
      expect(quiescedBeforeDelete, isTrue);
      expect(failed.service.authenticated, isTrue);
      expect(failed.service.renewal, isNotNull);
      expect(failed.service.follows, isNotNull);

      final value = await _service();
      addTearDown(() async {
        value.service.dispose();
        await value.db.close();
      });
      value.service.session = {
        'access_token': 'a',
        'refresh_token': 'r',
        'user': {'email': 'a@b.test'},
      };
      await value.service.deleteAccount();
      expect(value.service.authenticated, isFalse);
      expect(value.service.renewal, isNull);
      expect(value.service.rotation, isNull);
      expect(value.service.follows, isNull);
      expect((await value.service.loadProfileSettings()).displayName, isNull);
    },
  );

  test('sign out clears the session and leaves no renewal timer', () async {
    final value = await _service();
    addTearDown(() async {
      value.service.dispose();
      await value.db.close();
    });
    await value.service.signIn('user@example.com', 'password-test');
    await value.service.signOut();
    expect(value.service.authenticated, isFalse);
    expect(value.service.renewal, isNull);
    expect(value.service.follows, isNull);
  });

  testWidgets('guest profile remains usable and never requires an account', (
    tester,
  ) async {
    final value = await _service();
    addTearDown(() async {
      value.service.dispose();
      await value.db.close();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pushServiceProvider.overrideWithValue(value.service),
          databaseProvider.overrideWithValue(value.db),
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
    expect(find.text('Mis favoritos'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -1400));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Crear cuenta'), findsOneWidget);
    expect(find.text('¿Olvidaste tu contraseña?'), findsOneWidget);
    expect(find.text('Eliminar cuenta'), findsNothing);
  });

  testWidgets(
    'account deletion requires confirmation and cancel does not call service',
    (tester) async {
      final value = await _service();
      addTearDown(() async {
        value.service.dispose();
        await value.db.close();
      });
      value.service.session = {
        'access_token': 'a',
        'user': {'email': 'a@b.test', 'email_confirmed_at': 'now'},
      };
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            pushServiceProvider.overrideWithValue(value.service),
            databaseProvider.overrideWithValue(value.db),
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
      await tester.drag(find.byType(ListView), const Offset(0, -5000));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Eliminar cuenta'));
      await tester.pumpAndSettle();
      expect(find.text('Eliminar definitivamente'), findsOneWidget);
      expect(
        value.http.calls.where(
          (call) => call.path.endsWith('futbeat-delete-account'),
        ),
        isEmpty,
      );
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(value.service.authenticated, isTrue);
    },
  );

  testWidgets(
    'confirming deletion calls the service once and returns to guest',
    (tester) async {
      final value = await _service();
      addTearDown(() async {
        value.service.dispose();
        await value.db.close();
      });
      value.service.session = {
        'access_token': 'a',
        'user': {'email': 'a@b.test', 'email_confirmed_at': 'now'},
      };
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            pushServiceProvider.overrideWithValue(value.service),
            databaseProvider.overrideWithValue(value.db),
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
      await tester.drag(find.byType(ListView), const Offset(0, -5000));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Eliminar cuenta'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Eliminar definitivamente'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        value.http.calls.where(
          (call) => call.path.endsWith('futbeat-delete-account'),
        ),
        hasLength(1),
      );
      expect(value.service.authenticated, isFalse);
      expect(find.text('Iniciar sesión'), findsOneWidget);
    },
  );
}

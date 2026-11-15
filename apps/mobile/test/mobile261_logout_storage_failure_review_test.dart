import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/push.dart';
import 'package:futbeat/core/auth_errors.dart';
import 'package:futbeat/features/profile/account_security_screen.dart';

class _Tokens implements PushTokenSource {
  @override
  Future<String?> currentToken() async => null;
  @override
  Future<String?> requestToken() async => null;
  @override
  Stream<String> get rotations => const Stream.empty();
}

class _FailsOnce extends FlutterSecureStorage {
  _FailsOnce(this.operation, {this.permanent = false});
  final String operation;
  bool permanent;
  bool failed = false;
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
    if ((!failed || permanent) &&
        operation == 'session-delete' &&
        key == 'futbeat.push.session') {
      failed = true;
      throw StateError('Synthetic single storage deletion failure');
    }
    await super.delete(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }

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
    if (permanent ||
        (!failed &&
            operation == 'push-flag' &&
            key == 'futbeat.push.enabled' &&
            value == 'false')) {
      failed = true;
      throw StateError('Synthetic single storage flag failure');
    }
    await super.write(
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
}

class _Service extends PushService {
  _Service(AppDatabase db, Dio dio, this.testStorage)
    : super(
        const LiveRealtimeConfig(
          supabaseUrl: 'https://fixture.invalid',
          publicKey: 'synthetic-public',
        ),
        db,
        _Tokens(),
        dio: dio,
        pushConfigured: false,
        clock: () => DateTime.utc(2026, 11, 3, 12),
      );
  final FlutterSecureStorage testStorage;
  @override
  FlutterSecureStorage get storage => testStorage;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'unconfirmed logout remains retryable and blocks another account until repaired',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final session = <String, dynamic>{
        'access_token': 'synthetic-access-a',
        'refresh_token': 'synthetic-refresh-a',
        'user': {'id': 'synthetic-account-a'},
      };
      FlutterSecureStorage.setMockInitialValues({
        'futbeat.push.session': jsonEncode(session),
      });
      final db = AppDatabase(NativeDatabase.memory());
      final storage = _FailsOnce('session-delete', permanent: true);
      var passwordRequests = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              if (request.uri.queryParameters['grant_type'] == 'password') {
                passwordRequests++;
              }
              handler.reject(
                DioException(
                  requestOptions: request,
                  type: DioExceptionType.connectionError,
                ),
              );
            },
          ),
        );
      final service = _Service(db, dio, storage)..session = session;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        service.dispose();
        await db.close();
      });
      Future<void> flushUntil(bool Function() condition) async {
        for (var i = 0; i < 40 && !condition(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(condition(), isTrue);
        await tester.pump();
      }

      await tester.pumpWidget(
        ProviderScope(
          overrides: [pushServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: AccountSecurityScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final logout = find.byKey(const ValueKey('account-logout'));
      await tester.ensureVisible(logout);
      await tester.tap(logout);
      await flushUntil(
        () => find.text(authFallbackMessage).evaluate().isNotEmpty,
      );
      expect(service.hasUnconfirmedSignOut, isTrue);
      expect(await storage.read(key: 'futbeat.push.session'), isNotNull);
      expect(logout, findsOneWidget);
      expect(find.byKey(const ValueKey('account-login')), findsNothing);
      await expectLater(
        service.signIn('b@example.test', 'synthetic-password'),
        throwsA(isA<StateError>()),
      );
      expect(passwordRequests, 0);
      storage.permanent = false;
      await tester.ensureVisible(logout);
      await tester.tap(logout);
      await flushUntil(() => !service.hasUnconfirmedSignOut);
      expect(await storage.read(key: 'futbeat.push.session'), isNull);
      expect(find.text('Sin sesión iniciada'), findsOneWidget);
      expect(find.text('Sesión cerrada.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'failed logout keeps a retry action while its session is still stored',
    (tester) async {
      final session = <String, dynamic>{
        'access_token': 'synthetic-access-a',
        'refresh_token': 'synthetic-refresh-a',
        'expires_at':
            DateTime.utc(2026, 11, 3, 13).millisecondsSinceEpoch ~/ 1000,
        'user': {'id': 'synthetic-account-a', 'email': 'a@example.test'},
      };
      FlutterSecureStorage.setMockInitialValues({
        'futbeat.push.session': jsonEncode(session),
      });
      final storage = _FailsOnce('session-delete');
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (r, h) => h.reject(
              DioException(
                requestOptions: r,
                type: DioExceptionType.connectionError,
              ),
            ),
          ),
        );
      final service = _Service(db, dio, storage)..session = session;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        service.dispose();
        dio.close(force: true);
        await db.close();
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [pushServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: AccountSecurityScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('account-logout')));
      await tester.tap(find.byKey(const ValueKey('account-logout')));
      await tester.pumpAndSettle();
      final stored = await storage.read(key: 'futbeat.push.session');
      final retryVisible = find
          .byKey(const ValueKey('account-logout'))
          .evaluate()
          .isNotEmpty;
      debugPrint(
        'AUTH261 UI guest=${find.text('Sin sesión iniciada').evaluate().isNotEmpty} logoutRetry=$retryVisible storedSession=${stored != null} success=${find.text('Sesión cerrada.').evaluate().isNotEmpty} error=${find.text(authFallbackMessage).evaluate().isNotEmpty}',
      );
      if (stored != null) expect(find.text('Sesión cerrada.'), findsNothing);
      expect(
        stored == null || retryVisible,
        isTrue,
        reason: 'A failed operation with a retained session must leave a way to retry logout',
      );
    },
  );

  test(
    'persistent storage mutation failure reports closure NOT CONFIRMED',
    () async {
      final session = <String, dynamic>{
        'access_token': 'synthetic-access-a',
        'refresh_token': 'synthetic-refresh-a',
        'user': {'id': 'synthetic-account-a'},
      };
      FlutterSecureStorage.setMockInitialValues({
        'futbeat.push.session': jsonEncode(session),
      });
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (r, h) => h.reject(
              DioException(
                requestOptions: r,
                type: DioExceptionType.connectionError,
              ),
            ),
          ),
        );
      final storage = _FailsOnce('session-delete', permanent: true);
      final service = _Service(db, dio, storage)..session = session;
      addTearDown(() async {
        service.dispose();
        dio.close(force: true);
        await db.close();
      });
      await expectLater(service.signOut(), throwsA(isA<StateError>()));
      expect(await storage.read(key: 'futbeat.push.session'), isNotNull);
      debugPrint(
        'AUTH261 persistentMutationFailure closure=NOT_CONFIRMED visibleError=true',
      );
    },
  );
  // Reviewed against root9b2bac4, push blob baa92ec7694c859d2b7e0af04af0223c248c5a73.
  // Synthetic storage/server faults: no actual authentication or device QA.
  for (final scenario in [
    'session-delete',
    'push-flag',
    'session-delete-retry',
  ]) {
    final operation = scenario == 'session-delete-retry'
        ? 'session-delete'
        : scenario;
    test('logout cannot restore old account after one $scenario failure', () async {
      final session = <String, dynamic>{
        'access_token': 'synthetic-access-a',
        'refresh_token': 'synthetic-refresh-a',
        'expires_at':
            DateTime.utc(2026, 11, 3, 13).millisecondsSinceEpoch ~/ 1000,
        'user': {'id': 'synthetic-account-a', 'email': 'a@example.test'},
      };
      FlutterSecureStorage.setMockInitialValues({
        'futbeat.push.session': jsonEncode(session),
        'futbeat.push.enabled': 'true',
      });
      final storage = _FailsOnce(operation);
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) => handler.reject(
              DioException(
                requestOptions: request,
                type: DioExceptionType.connectionError,
                error: 'Synthetic offline server',
              ),
            ),
          ),
        );
      final service = _Service(db, dio, storage)..session = session;
      final reopened = _Service(db, dio, storage);
      addTearDown(() async {
        service.dispose();
        reopened.dispose();
        await service.signOutCleanup;
        await reopened.signOutCleanup;
        dio.close(force: true);
        await db.close();
      });
      Object? visibleError;
      try {
        await service.signOut();
      } catch (error) {
        visibleError = error;
      }
      expect(storage.failed, isTrue);
      expect(service.authenticated, isFalse);
      expect(service.enabled, isFalse);
      debugPrint(
        'AUTH261 operation=$operation visibleError=${visibleError != null} localClosed=${!service.authenticated}',
      );
      if (scenario == 'session-delete-retry') await service.signOut();
      await reopened.restore();
      expect(
        reopened.authenticated,
        isFalse,
        reason: 'The user sign-out intent must not silently restore the previous account after reopening',
      );
    });
  }
}

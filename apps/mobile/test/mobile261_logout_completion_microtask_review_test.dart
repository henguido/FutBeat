import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/push.dart';

class _Tokens implements PushTokenSource {
  @override
  Future<String?> currentToken() async => 'synthetic-device-a';
  @override
  Future<String?> requestToken() async => 'synthetic-device-a';
  @override
  Stream<String> get rotations => const Stream.empty();
}

class _HeldMetadata extends FlutterSecureStorage {
  bool armed = false;
  int depth = 0;
  void Function()? afterComplete;
  final entered = Completer<void>();
  final release = Completer<void>();
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
    if (armed && key == 'futbeat.push.enabled' && value == 'false') {
      armed = false;
      entered.complete();
      await release.future;
      void schedule(int remaining) {
        scheduleMicrotask(() {
          if (remaining == 0) {
            afterComplete!();
          } else {
            schedule(remaining - 1);
          }
        });
      }

      schedule(depth);
    }
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
        pushConfigured: true,
        clock: () => DateTime.utc(2026, 11, 3, 12),
        signOutCleanupTimeout: const Duration(milliseconds: 40),
      );
  final FlutterSecureStorage testStorage;
  @override
  FlutterSecureStorage get storage => testStorage;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Review exact A7 commit21b4c16, push blob7d2bf94dba9e9d5fc6e4451ccaa6ce673b2215e6.
  for (final depth in List.generate(25, (i) => i)) {
    test('explicit logout after flag completion microtask $depth', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final storage = _HeldMetadata()..depth = depth;
      const mode = 'microtask';
      final db = AppDatabase(NativeDatabase.memory());
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              requests.add(request);
              if (request.path.contains('/auth/v1/logout') &&
                  mode.endsWith('hung-remote')) {
                unawaited(
                  request.cancelToken!.whenCancel.then(
                    (error) => handler.reject(error),
                  ),
                );
                return;
              }
              Object? result;
              if (request.path.contains('/auth/v1/token')) {
                final suffix =
                    (request.data as Map)['email'] == 'b@example.test'
                    ? 'b'
                    : 'a';
                result = {
                  'access_token': 'synthetic-access-$suffix',
                  'refresh_token': 'synthetic-refresh-$suffix',
                  'expires_at':
                      DateTime.utc(2026, 11, 3, 13).millisecondsSinceEpoch ~/
                      1000,
                  'user': {
                    'id': 'synthetic-account-$suffix',
                    'email': '$suffix@example.test',
                  },
                };
              } else if (request.path.endsWith('futbeat_read_user_profile')) {
                final b =
                    request.headers['Authorization'] ==
                    'Bearer synthetic-access-b';
                result = {
                  'preferences': <String, dynamic>{},
                  'follows': [
                    {'type': 'team', 'id': b ? 'fb_team_b' : 'fb_team_a'},
                  ],
                };
              }
              handler.resolve(
                Response(
                  requestOptions: request,
                  statusCode: 200,
                  data: result,
                ),
              );
            },
          ),
        );
      final service = _Service(db, dio, storage);
      addTearDown(() async {
        if (!storage.release.isCompleted) storage.release.complete();
        service.dispose();
        await service.pending;
        await service.signOutCleanup;
        dio.close(force: true);
        await db.close();
      });
      await service.signIn('a@example.test', 'synthetic-password');
      await service.pending;
      await service.enable(prompt: false);
      expect(service.enabled, isTrue);
      storage.armed = true;
      final replacing = service.signIn('b@example.test', 'synthetic-password');
      await storage.entered.future;
      final fired = Completer<void>();
      late Future<void> logout;
      var pendingAtCall = false;
      storage.afterComplete = () {
        pendingAtCall = service.hasUnconfirmedSignOut;
        logout = service.signOut();
        fired.complete();
      };
      storage.release.complete();
      await fired.future;
      await Future.wait([replacing, logout]);
      await service.pending;
      expect(
        service.authenticated,
        isFalse,
        reason: 'Explicit logout must cancel replacement even at completion boundary',
      );
      expect(
        await storage.read(key: 'futbeat.push.session'),
        isNull,
        reason:
            'Logout ACK must not leave a persisted credential; pendingAtCall=$pendingAtCall depth=$depth',
      );
    });
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/push.dart';

class _Tokens implements PushTokenSource {
  @override
  Future<String?> currentToken() async => 'synthetic-device-token';
  @override
  Future<String?> requestToken() => currentToken();
  @override
  Stream<String> get rotations => const Stream.empty();
}

class _HeldCleanupStorage extends FlutterSecureStorage {
  bool armed = false;
  final captured = Completer<void>();
  final release = Completer<void>();
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
    final value = await super.read(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
    if (armed && key == PushService.pushedKey('synthetic-A')) {
      armed = false;
      captured.complete();
      await release.future;
    }
    return value;
  }
}

class _Service extends PushService {
  _Service(
    AppDatabase db,
    Dio dio,
    this.testStorage, {
    Duration deadline = const Duration(seconds: 5),
  }) : super(
         const LiveRealtimeConfig(
           supabaseUrl: 'https://fixture.invalid',
           publicKey: 'synthetic',
         ),
         db,
         _Tokens(),
         dio: dio,
         pushConfigured: true,
         signOutCleanupTimeout: deadline,
       );
  final FlutterSecureStorage testStorage;
  @override
  FlutterSecureStorage get storage => testStorage;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final localTimeout in [false, true]) {
    test('new account waits for old local cleanup (timeout=$localTimeout)', () async {
      Map<String, dynamic> session(String user) => {
        'access_token': 'synthetic-$user',
        'refresh_token': 'synthetic-refresh-$user',
        'expires_at':
            DateTime.now()
                .add(const Duration(hours: 1))
                .millisecondsSinceEpoch ~/
            1000,
        'user': {'id': user},
      };
      FlutterSecureStorage.setMockInitialValues({
        'futbeat.push.session': jsonEncode(session('synthetic-A')),
        PushService.pushedKey('synthetic-A'): jsonEncode(['team:fb_team_A']),
      });
      final db = AppDatabase(NativeDatabase.memory());
      await db.addFollows(['team:fb_team_A']);
      final dio = Dio();
      var loginStarted = false;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            final grant = request.uri.queryParameters['grant_type'];
            if (grant == 'password') loginStarted = true;
            final b =
                request.headers['Authorization'] ==
                'Bearer synthetic-synthetic-B';
            handler.resolve(
              Response(
                requestOptions: request,
                data: grant == 'password'
                    ? session('synthetic-B')
                    : grant == 'refresh_token'
                    ? session('synthetic-A')
                    : request.path.endsWith('futbeat_read_user_profile')
                    ? {
                        'preferences': null,
                        'follows': [
                          {'type': 'team', 'id': b ? 'fb_team_B' : 'fb_team_A'},
                        ],
                      }
                    : <String, dynamic>{},
              ),
            );
          },
        ),
      );
      final storage = _HeldCleanupStorage();
      final service = _Service(
        db,
        dio,
        storage,
        deadline: localTimeout
            ? const Duration(milliseconds: 20)
            : const Duration(seconds: 5),
      );
      addTearDown(() async {
        if (!storage.release.isCompleted) storage.release.complete();
        service.dispose();
        await db.close();
      });
      await service.restore();
      storage.armed = true;
      final logout = service.signOut();
      await storage.captured.future.timeout(const Duration(seconds: 3));
      final login = service
          .signIn('b@example.test', 'synthetic-password')
          .then<Object?>((_) => null, onError: (Object error) => error);
      await Future<void>.delayed(
        Duration(milliseconds: localTimeout ? 60 : 30),
      );
      final startedBeforeCleanup = loginStarted;
      storage.release.complete();
      await logout;
      final loginResult = await login;
      if (localTimeout) {
        expect(
          loginResult,
          isA<TimeoutException>(),
          reason: 'critical local cleanup timeout must fail login, not skip isolation',
        );
        await service.signIn('b@example.test', 'synthetic-password');
      } else {
        expect(loginResult, isNull);
      }
      await service.enable();
      final followKeys = await db.watchFollows().first;
      final leftover = await storage.read(key: PushService.leftoverKey);
      final wrongLeftover =
          leftover != null &&
          (jsonDecode(leftover)['follows'] as List).contains('team:fb_team_B');
      debugPrint(
        'AUTH261 overlap earlyLogin=$startedBeforeCleanup oldFollowInNewAccount=${followKeys.contains('team:fb_team_A')} newAccountMarkedAsOldLeftover=$wrongLeftover',
      );
      expect(
        startedBeforeCleanup,
        isFalse,
        reason:
            'new authentication must not race the prior account local cleanup',
      );
      expect(service.userId, 'synthetic-B');
      expect(followKeys, {'team:fb_team_B'});
      expect(await storage.read(key: 'futbeat.push.enabled'), 'true');
      expect(
        leftover == null ||
            !(jsonDecode(leftover)['follows'] as List).contains(
              'team:fb_team_B',
            ),
        isTrue,
      );
    });
  }
}

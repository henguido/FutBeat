import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/push.dart';

class _Tokens implements PushTokenSource {
  @override
  Future<String?> currentToken() async => null;
  @override
  Future<String?> requestToken() async => null;
  @override
  Stream<String> get rotations => const Stream.empty();
}

class _ReadFailure extends FlutterSecureStorage {
  _ReadFailure(this.failedKey);
  final String failedKey;
  final reads = <String, int>{};
  bool failed = false;
  bool failDelete = false;
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
    if (key == 'futbeat.push.session' && failDelete) {
      throw PlatformException(code: 'synthetic-session-delete-locked');
    }
    return super.delete(
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
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    reads.update(key, (value) => value + 1, ifAbsent: () => 1);
    if (key == failedKey && !failed) {
      failed = true;
      throw PlatformException(code: 'synthetic-session-locked');
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

class _Service extends PushService {
  _Service(AppDatabase db, Dio dio, this.testStorage)
    : super(
        const LiveRealtimeConfig(
          supabaseUrl: 'https://fixture.invalid',
          publicKey: 'synthetic',
        ),
        db,
        _Tokens(),
        dio: dio,
        pushConfigured: false,
      );
  final FlutterSecureStorage testStorage;
  @override
  FlutterSecureStorage get storage => testStorage;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late Dio dio;
  late _Service service;
  late _ReadFailure storage;
  var refreshes = 0;
  Map<String, dynamic> session() => {
    'access_token': 'synthetic-access',
    'refresh_token': 'synthetic-refresh',
    'expires_at':
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
        1000,
    'user': {'id': 'synthetic-A'},
  };
  void prepare(String key, {bool signedIn = true}) {
    FlutterSecureStorage.setMockInitialValues(
      signedIn ? {'futbeat.push.session': jsonEncode(session())} : {},
    );
    db = AppDatabase(NativeDatabase.memory());
    refreshes = 0;
    dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            final refresh =
                request.uri.queryParameters['grant_type'] == 'refresh_token';
            if (refresh) refreshes++;
            handler.resolve(
              Response(
                requestOptions: request,
                data: refresh
                    ? session()
                    : request.path.endsWith('futbeat_read_user_profile')
                    ? {'preferences': null, 'follows': <dynamic>[]}
                    : <String, dynamic>{},
              ),
            );
          },
        ),
      );
    storage = _ReadFailure(key);
    service = _Service(db, dio, storage);
  }

  tearDown(() async {
    service.dispose();
    await db.close();
  });

  for (final key in [
    'futbeat.auth.pendingConfirmationEmail',
    'futbeat.push.session',
  ]) {
    for (final retry in ['restore', 'resume']) {
      test(
        '$retry recovers persisted session after initial $key IO failure',
        () async {
          prepare(key);
          final saved = await const FlutterSecureStorage().read(
            key: 'futbeat.push.session',
          );
          await service.restore();
          expect(service.authenticated, isFalse);
          expect(
            await const FlutterSecureStorage().read(
              key: 'futbeat.push.session',
            ),
            saved,
          );
          expect(refreshes, 0);
          await Future.wait([
            retry == 'restore' ? service.restore() : service.resume(),
            retry == 'restore' ? service.restore() : service.resume(),
          ]);
          expect(service.userId, 'synthetic-A');
          expect(service.authenticated, isTrue);
          expect(
            refreshes,
            1,
            reason: 'concurrent retries must share restoration',
          );
        },
      );
    }
  }
  for (final retry in ['restore', 'resume']) {
    test('explicit failed logout cancels an older storage retry before $retry', () async {
      prepare('futbeat.push.session');
      await service.restore();
      expect(service.authenticated, isFalse);
      storage.failDelete = true;
      await expectLater(service.signOut(), throwsA(isA<PlatformException>()));
      // The disk failure is acknowledged; it must not authorize an automatic
      // return to this account in the current service after an explicit logout.
      expect(
        await const FlutterSecureStorage().read(key: 'futbeat.push.session'),
        isNotNull,
      );
      if (retry == 'restore') {
        await service.restore();
      } else {
        await service.resume();
      }
      expect(service.authenticated, isFalse);
      expect(refreshes, 0);
    });
  }
  test('a recovered empty store stays guest and successful restore remains memoized', () async {
    prepare('futbeat.auth.pendingConfirmationEmail', signedIn: false);
    await service.restore();
    await service.restore();
    expect(storage.reads['futbeat.push.session'], 1);
    await service.restore();
    await service.resume();
    expect(storage.reads['futbeat.push.session'], 1);
    expect(service.authenticated, isFalse);
    expect(refreshes, 0);
  });
  test(
    'explicit logout before retry cannot restore the old stored session',
    () async {
      prepare('futbeat.push.session');
      await service.restore();
      await service.signOut();
      await service.signOutCleanup;
      await service.restore();
      await service.resume();
      expect(service.authenticated, isFalse);
      expect(await storage.read(key: 'futbeat.push.session'), isNull);
      expect(refreshes, 0);
    },
  );
}

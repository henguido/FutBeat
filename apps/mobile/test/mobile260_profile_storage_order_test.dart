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
  Future<String?> currentToken() async => null;
  @override
  Future<String?> requestToken() async => null;
  @override
  Stream<String> get rotations => const Stream.empty();
}

class _Storage extends FlutterSecureStorage {
  _Storage({this.holdAck = false, this.failFirst = false});
  final bool holdAck;
  final bool failFirst;
  final captured = Completer<void>();
  final release = Completer<void>();
  final secondWritten = Completer<void>();
  int settingsWrites = 0;
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
    final index = key == 'futbeat.profile.settings' ? ++settingsWrites : 0;
    final held = holdAck
        ? key == 'futbeat.profile.dirty' && value == 'false'
        : index == 1;
    if (held && !captured.isCompleted) {
      captured.complete();
      await release.future;
      if (failFirst) throw StateError('synthetic write failure');
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
    if (index == 2 && !secondWritten.isCompleted) secondWritten.complete();
  }
}

class _HeldProfileRead extends FlutterSecureStorage {
  _HeldProfileRead({this.heldKey = 'futbeat.profile.settings'});
  final String heldKey;
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
    if (key == heldKey && !captured.isCompleted) {
      captured.complete();
      await release.future;
    }
    return value;
  }
}

class _Service extends PushService {
  _Service(AppDatabase database, Dio dio, this.testStorage)
    : super(
        const LiveRealtimeConfig(
          supabaseUrl: 'https://fixture.invalid',
          publicKey: 'synthetic-public',
        ),
        database,
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
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  for (final fails in [false, true]) {
    test(
      'latest guest preference survives delayed ${fails ? 'failed' : 'successful'} prior write',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        final dio = Dio();
        final storage = _Storage(failFirst: fails);
        final service = _Service(db, dio, storage);
        addTearDown(() async {
          service.dispose();
          await db.close();
        });
        final first = service
            .saveProfileSettings(const UserProfileSettings(hourFormat: '12h'))
            .then((_) => true, onError: (_) => false);
        await storage.captured.future;
        final latest = service.saveProfileSettings(
          const UserProfileSettings(hourFormat: '24h'),
        );
        await Future.any([
          storage.secondWritten.future,
          Future<void>.delayed(Duration.zero),
        ]);
        storage.release.complete();
        expect(await first, !fails);
        await latest;
        expect((await service.loadProfileSettings()).hourFormat, '24h');
        expect(await storage.read(key: 'futbeat.profile.dirty'), 'true');
      },
    );
  }
  test('old acknowledgement cannot clear dirty while a newer edit is queued', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final dio = Dio();
    final storage = _Storage(holdAck: true);
    final service = _Service(db, dio, storage)
      ..session = {
        'access_token': 'synthetic-access',
        'refresh_token': 'synthetic-refresh',
        'user': {'id': 'synthetic-user'},
      };
    addTearDown(() async {
      service.dispose();
      await db.close();
    });
    var calls = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          if (++calls == 1) {
            handler.resolve(
              Response(requestOptions: request, data: <String, dynamic>{}),
            );
          } else {
            handler.reject(
              DioException(
                requestOptions: request,
                type: DioExceptionType.connectionError,
              ),
            );
          }
        },
      ),
    );
    final old = service.saveProfileSettings(
      const UserProfileSettings(hourFormat: '12h'),
    );
    await storage.captured.future;
    final latest = service
        .saveProfileSettings(const UserProfileSettings(hourFormat: '24h'))
        .then((_) => true, onError: (_) => false);
    await Future.any([
      storage.secondWritten.future,
      Future<void>.delayed(Duration.zero),
    ]);
    // Let an unqueued dirty=true write complete too, before releasing old ACK.
    await Future<void>.delayed(Duration.zero);
    storage.release.complete();
    await old;
    expect(await latest, isFalse);
    expect((await service.loadProfileSettings()).hourFormat, '24h');
    expect(await storage.read(key: 'futbeat.profile.dirty'), 'true');
    expect(calls, 2);
  });
  test(
    'late server write leaves latest local profile dirty for retry',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio();
      final service = _Service(db, dio, const FlutterSecureStorage())
        ..session = {
          'access_token': 'synthetic-access',
          'refresh_token': 'synthetic-refresh',
          'expires_at':
              DateTime.now()
                  .add(const Duration(hours: 1))
                  .millisecondsSinceEpoch ~/
              1000,
          'user': {'id': 'synthetic-user'},
        };
      addTearDown(() async {
        service.dispose();
        await db.close();
      });
      final oldStarted = Completer<void>();
      final releaseOld = Completer<void>();
      var calls = 0;
      var remoteHour = 'system';
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) async {
            if (request.path.endsWith('futbeat_sync_user_profile_v3')) {
              if (++calls == 1) {
                oldStarted.complete();
                await releaseOld.future;
              }
              remoteHour =
                  ((request.data as Map)['p_profile'] as Map)['hourFormat']
                      as String;
            }
            handler.resolve(
              Response(
                requestOptions: request,
                data: request.path.endsWith('futbeat_read_user_profile')
                    ? {
                        'preferences': {'hourFormat': remoteHour},
                        'follows': <Object>[],
                      }
                    : <String, dynamic>{},
              ),
            );
          },
        ),
      );
      final old = service.saveProfileSettings(
        const UserProfileSettings(hourFormat: '12h'),
      );
      await oldStarted.future;
      await service.saveProfileSettings(
        const UserProfileSettings(hourFormat: '24h'),
      );
      expect(remoteHour, '24h');
      releaseOld.complete();
      await old;
      expect(
        remoteHour,
        '12h',
        reason: 'simulated old remote write really landed last',
      );
      expect((await service.loadProfileSettings()).hourFormat, '24h');
      expect(await service.storage.read(key: 'futbeat.profile.dirty'), 'true');
      await service.resume();
      expect(remoteHour, '24h');
      expect(await service.storage.read(key: 'futbeat.profile.dirty'), 'false');
      expect(calls, 3, reason: 'one bounded retry of the latest local value');
    },
  );
  test('pending preference save cannot upload to a later account', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final dio = Dio();
    final storage = _Storage();
    final service = _Service(db, dio, storage)
      ..session = {
        'access_token': 'synthetic-A',
        'refresh_token': 'synthetic-refresh-A',
        'user': {'id': 'synthetic-A'},
      };
    addTearDown(() async {
      service.dispose();
      await db.close();
    });
    final profileCalls = <RequestOptions>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          if (request.path.contains('sync_user_profile'))
            profileCalls.add(request);
          handler.resolve(
            Response(requestOptions: request, data: <String, dynamic>{}),
          );
        },
      ),
    );
    final old = service.saveProfileSettings(
      const UserProfileSettings(hourFormat: '12h'),
    );
    await storage.captured.future;
    await service.signOut();
    await service.signOutCleanup;
    service.session = {
      'access_token': 'synthetic-B',
      'refresh_token': 'synthetic-refresh-B',
      'user': {'id': 'synthetic-B'},
    };
    storage.release.complete();
    await old;
    expect(
      profileCalls,
      isEmpty,
      reason: 'A preference intent must not use account B headers',
    );
  });
  for (final loggedOut in [false, true]) {
    test(
      'cloud reconciliation cannot erase preference edited during read (logout=$loggedOut)',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        final dio = Dio();
        final storage = _HeldProfileRead();
        final service = _Service(db, dio, storage)
          ..session = {
            'access_token': 'synthetic-A',
            'refresh_token': 'synthetic-refresh-A',
            'expires_at':
                DateTime.now()
                    .add(const Duration(hours: 1))
                    .millisecondsSinceEpoch ~/
                1000,
            'user': {'id': 'synthetic-A'},
          };
        addTearDown(() async {
          service.dispose();
          await db.close();
        });
        final profileCalls = <RequestOptions>[];
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              if (request.path.contains('sync_user_profile'))
                profileCalls.add(request);
              handler.resolve(
                Response(
                  requestOptions: request,
                  data: request.path.endsWith('futbeat_read_user_profile')
                      ? {
                          'preferences': {'hourFormat': '12h'},
                          'follows': <Object>[],
                        }
                      : <String, dynamic>{},
                ),
              );
            },
          ),
        );
        final reconcile = service.resume();
        await storage.captured.future;
        if (loggedOut) {
          await service.signOut();
          await service.signOutCleanup;
        }
        await service.saveProfileSettings(
          const UserProfileSettings(hourFormat: '24h'),
        );
        storage.release.complete();
        await reconcile;
        expect((await service.loadProfileSettings()).hourFormat, '24h');
        expect(
          await storage.read(key: 'futbeat.profile.dirty'),
          loggedOut ? 'true' : 'false',
        );
        expect(profileCalls, hasLength(loggedOut ? 0 : 1));
      },
    );
  }
  for (final loggedOut in [false, true]) {
    test(
      'cloud country read cannot erase newer manual country (logout=$loggedOut)',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        await db.savePreference(detectedCountry: 'CR', selectedCountry: 'CR');
        final dio = Dio();
        final storage = _HeldProfileRead(
          heldKey: 'futbeat.country.selected.dirty',
        );
        final service = _Service(db, dio, storage)
          ..session = {
            'access_token': 'synthetic-A',
            'refresh_token': 'synthetic-refresh-A',
            'expires_at':
                DateTime.now()
                    .add(const Duration(hours: 1))
                    .millisecondsSinceEpoch ~/
                1000,
            'user': {'id': 'synthetic-A'},
          };
        addTearDown(() async {
          service.dispose();
          await db.close();
        });
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              handler.resolve(
                Response(
                  requestOptions: request,
                  data: request.path.endsWith('futbeat_read_user_profile')
                      ? {
                          'preferences': {
                            'selectedCountry': 'US',
                            'detectedCountry': 'US',
                          },
                          'follows': <Object>[],
                        }
                      : <String, dynamic>{},
                ),
              );
            },
          ),
        );
        final reconcile = service.resume();
        await storage.captured.future;
        if (loggedOut) {
          await service.signOut();
          await service.signOutCleanup;
        }
        await db.saveSelectedCountry('MX');
        await service.markSelectedCountryDirty();
        storage.release.complete();
        await reconcile;
        expect((await db.watchPreference().first).selectedCountry, 'MX');
        expect(
          await storage.read(key: 'futbeat.country.selected.dirty'),
          'true',
        );
      },
    );
  }
}

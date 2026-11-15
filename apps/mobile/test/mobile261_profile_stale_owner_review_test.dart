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

class _HeldName extends FlutterSecureStorage {
  bool armed = false;
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
    if (armed && key == 'futbeat.profile.settings' && value != null) {
      armed = false;
      entered.complete();
      await release.future;
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
  for (final mode in ['cloud-name', 'local-name-pending']) {
    test('obsolete B name clear cannot overwrite newer A: $mode', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final db = AppDatabase(NativeDatabase.memory());
      final profiles = <String, Map<String, dynamic>>{
        'a': UserProfileSettings(
          displayName: mode == 'cloud-name' ? 'Account A' : null,
          hourFormat: '12h',
        ).toJson(),
        'b': UserProfileSettings(
          displayName: mode.startsWith('default') ? null : 'Account B',
          hourFormat: '12h',
        ).toJson(),
      };
      var rejectProfileWrites = false;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (r, h) {
              final uid = '${r.headers['Authorization']}'.endsWith('access-b')
                  ? 'b'
                  : 'a';
              Object? data;
              if (r.path.contains('/auth/v1/token')) {
                final id = (r.data as Map)['email'] == 'b@example.test'
                    ? 'b'
                    : 'a';
                data = {
                  'access_token': 'access-$id',
                  'refresh_token': 'refresh-$id',
                  'user': {'id': id},
                };
              } else if (r.path.endsWith('futbeat_read_user_profile')) {
                data = {
                  'preferences': {
                    ...profiles[uid]!,
                    'selectedCountry': 'US',
                    'detectedCountry': 'US',
                  },
                  'follows': <Object>[],
                };
              } else if (r.path.endsWith('futbeat_sync_user_profile_v3')) {
                if (rejectProfileWrites) {
                  h.reject(
                    DioException(
                      requestOptions: r,
                      type: DioExceptionType.connectionError,
                    ),
                  );
                  return;
                }
                profiles[uid] = Map<String, dynamic>.from(
                  (r.data as Map)['p_profile'] as Map,
                );
              }
              h.resolve(
                Response(requestOptions: r, statusCode: 200, data: data),
              );
            },
          ),
        );
      final storage = _HeldName();
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
      if (mode == 'local-name-pending') {
        rejectProfileWrites = true;
        try {
          final local = await service.loadProfileSettings();
          await service.saveProfileSettings(
            local.copyWith(displayName: 'Account A'),
          );
        } catch (_) {
          /* simulated offline profile save retains dirty local data */
        }
        expect(profiles['a']!['displayName'], isNull);
      }
      expect((await service.loadProfileSettings()).displayName, 'Account A');
      await service.signOut();
      {
        final guest = await service.loadProfileSettings();
        await service.saveProfileSettings(
          guest.copyWith(hourFormat: '24h', notifyGoals: false),
        );
        await db.saveSelectedCountry('MX');
        await service.markSelectedCountryDirty();
      }
      rejectProfileWrites = false;
      storage.armed = true;
      final replacing = service.signIn('b@example.test', 'synthetic-password');
      await storage.entered.future;
      final newer = service.signIn('a@example.test', 'synthetic-password');
      storage.release.complete();
      await Future.wait([replacing, newer]);
      await service.pending;
      const target = 'a';
      final local = await service.loadProfileSettings();
      final expected = target == 'a'
          ? 'Account A'
          : mode.startsWith('default')
          ? null
          : 'Account B';
      expect(local.displayName, expected);
      expect(profiles[target]!['displayName'], expected);
      expect(profiles['a']!['displayName'], 'Account A');
      {
        expect(local.hourFormat, '24h');
        expect(local.notifyGoals, isFalse);
        expect((await db.watchPreference().first).selectedCountry, 'MX');
      }
    });
  }
}

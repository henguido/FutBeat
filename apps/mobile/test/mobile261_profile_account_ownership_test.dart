import 'dart:async';
import 'dart:convert';

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
  bool failProfile = false;
  bool holdProfile = false;
  final entered = Completer<void>();
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
    final result = await super.read(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
    if (holdProfile && key == 'futbeat.profile.settings') {
      holdProfile = false;
      entered.complete();
      await release.future;
    }
    return result;
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
    if (failProfile && key == 'futbeat.profile.settings') {
      failProfile = false;
      throw StateError('Synthetic profile write IO');
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
  for (final mode in [
    'named-b-dirty',
    'default-b-clean',
    'default-b-dirty',
    'same-a-dirty',
    'retry-b-dirty',
    'latest-a-dirty',
    'concurrent-b-dirty',
    'burst-b-dirty',
    'legacy-b-dirty',
    'legacy-a-dirty',
    'marker-b-dirty',
    'legacy-marker-b-dirty',
    'legacy-owner-a-dirty',
  ]) {
    test('profile identity stays account scoped: $mode', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final db = AppDatabase(NativeDatabase.memory());
      final profiles = <String, Map<String, dynamic>>{
        'a': const UserProfileSettings(
          displayName: 'Account A',
          hourFormat: '12h',
        ).toJson(),
        'b': UserProfileSettings(
          displayName: mode.startsWith('default') ? null : 'Account B',
          hourFormat: '12h',
        ).toJson(),
      };
      final countries = <String, String?>{
        'a': mode == 'legacy-owner-a-dirty' ? 'MX' : 'US',
        'b': 'US',
      };
      var bReads = 0;
      var bWrites = 0;
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
                if (uid == 'b') bReads++;
                data = {
                  'preferences': {
                    ...profiles[uid]!,
                    'selectedCountry': countries[uid],
                    'detectedCountry': 'US',
                  },
                  'follows': <Object>[],
                };
              } else if (r.path.endsWith('futbeat_sync_user_profile_v3')) {
                if (uid == 'b') bWrites++;
                profiles[uid] = Map<String, dynamic>.from(
                  (r.data as Map)['p_profile'] as Map,
                );
              } else if (r.path.endsWith(
                'futbeat_sync_user_preference_fields',
              )) {
                if ((r.data as Map)['p_update_selected'] == true) {
                  countries[uid] = (r.data as Map)['p_selected'] as String?;
                }
              }
              h.resolve(
                Response(requestOptions: r, statusCode: 200, data: data),
              );
            },
          ),
        );
      final storage = _Storage();
      final service = _Service(db, dio, storage);
      addTearDown(() async {
        service.dispose();
        await service.pending;
        await service.signOutCleanup;
        dio.close(force: true);
        await db.close();
      });
      await service.signIn('a@example.test', 'synthetic-password');
      await service.pending;
      expect((await service.loadProfileSettings()).displayName, 'Account A');
      await service.signOut();
      if (mode.startsWith('legacy')) {
        final marker = Map<String, dynamic>.from(
          jsonDecode((await storage.read(key: PushService.leftoverKey))!)
              as Map,
        );
        marker.remove('profileUserId');
        marker.remove('profileDisplayName');
        await storage.write(
          key: PushService.leftoverKey,
          value: jsonEncode(marker),
        );
      }
      if (mode.endsWith('dirty')) {
        final guest = await service.loadProfileSettings();
        await service.saveProfileSettings(
          guest.copyWith(hourFormat: '24h', notifyGoals: false),
        );
        await db.saveSelectedCountry('MX');
        await service.markSelectedCountryDirty();
      }
      if (mode == 'marker-b-dirty' ||
          mode == 'legacy-marker-b-dirty' ||
          mode == 'legacy-owner-a-dirty') {
        storage.failProfile = true;
        await service.signIn('b@example.test', 'synthetic-password');
        await service.pending;
        await service.signOut();
        final marker = jsonDecode(
          (await storage.read(key: PushService.leftoverKey))!,
        ) as Map;
        expect(marker['userId'], 'b');
        expect(marker['profileUserId'], 'a');
      }
      if (mode == 'retry-b-dirty') {
        storage.failProfile = true;
        await service.signIn('b@example.test', 'synthetic-password');
        expect(service.userId, 'b');
        expect(await storage.read(key: PushService.leftoverKey), isNotNull);
        expect((await service.loadProfileSettings()).displayName, 'Account A');
      }
      var target = mode == 'same-a-dirty' || mode == 'legacy-a-dirty'
          ? 'a'
          : 'b';
      if (mode == 'legacy-owner-a-dirty') {
        storage.failProfile = true;
        await service.signIn('a@example.test', 'synthetic-password');
        await service.pending;
        final retained = jsonDecode(
          (await storage.read(key: PushService.leftoverKey))!,
        ) as Map;
        expect(retained['profileUserId'], 'a');
        expect(retained.containsKey('profileDisplayName'), isFalse);
        target = 'a';
      }
      if (mode == 'latest-a-dirty' ||
          mode == 'concurrent-b-dirty' ||
          mode == 'burst-b-dirty' ||
          mode == 'marker-b-dirty' ||
          mode == 'legacy-marker-b-dirty') {
        final guest = await service.loadProfileSettings();
        storage.holdProfile = true;
        final b = service.signIn('b@example.test', 'synthetic-password');
        await storage.entered.future;
        if (mode == 'latest-a-dirty') {
          final a = service.signIn('a@example.test', 'synthetic-password');
          storage.release.complete();
          await Future.wait([a, b]);
          target = 'a';
        } else {
          final saving = service.saveProfileSettings(
            guest.copyWith(hourFormat: '24h', notifyGoals: false),
          );
          final second = mode == 'burst-b-dirty'
              ? service.saveProfileSettings(
                  guest.copyWith(hourFormat: '24h', notifyGoals: false),
                )
              : Future<void>.value();
          storage.release.complete();
          await Future.wait([saving, second, b]);
        }
      } else {
        await service.signIn('$target@example.test', 'synthetic-password');
      }
      await service.pending;
      final local = await service.loadProfileSettings();
      final expected = target == 'a'
          ? 'Account A'
          : mode.startsWith('default')
          ? null
          : 'Account B';
      expect(local.displayName, expected);
      expect(profiles[target]!['displayName'], expected);
      expect(profiles['a']!['displayName'], 'Account A');
      if (mode == 'burst-b-dirty') {
        expect(
          bReads,
          2,
          reason: 'initial read plus one queued reconciliation',
        );
        expect(
          bWrites,
          1,
          reason: 'concurrent saves share the successful reconciliation',
        );
      }
      if (mode.endsWith('dirty')) {
        expect(local.hourFormat, '24h');
        expect(local.notifyGoals, isFalse);
        expect((await db.watchPreference().first).selectedCountry, 'MX');
      }
    });
  }
}

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
  bool holdRead = false;
  final readEntered = Completer<void>();
  final readRelease = Completer<void>();
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
    if (holdRead && key == 'futbeat.profile.settings') {
      holdRead = false;
      readEntered.complete();
      await readRelease.future;
    }
    return value;
  }

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
    if (armed && key == PushService.leftoverKey) {
      armed = false;
      entered.complete();
      await release.future;
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
  for (final afterConsumption in [false, true]) {
    test(
      'field intent preserves B during/after marker consumption: $afterConsumption',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        final db = AppDatabase(NativeDatabase.memory());
        final profiles = <String, Map<String, dynamic>>{
          'a': UserProfileSettings(
            displayName: 'Account A',
            hourFormat: '12h',
          ).toJson(),
          'b': UserProfileSettings(
            displayName: 'Account B',
            hourFormat: '12h',
          ).toJson(),
        };

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
        expect((await service.loadProfileSettings()).displayName, 'Account A');
        await service.signOut();
        final staleGuest = await service.loadProfileSettings();
        expect(staleGuest.displayName, 'Account A');
        storage.armed = !afterConsumption;
        final loginB = service.signIn('b@example.test', 'synthetic-password');
        if (afterConsumption) {
          await loginB;
        } else {
          await storage.entered.future;
        }
        expect(service.userId, 'b');
        expect((await service.loadProfileSettings()).displayName, 'Account B');
        expect(
          profiles['b']!['displayName'],
          'Account B',
          reason: 'B profile ACK completed before marker consumption',
        );
        await expectLater(
          service.updateProfileSettings(
            (current) => current.copyWith(displayName: 'Old account edit'),
            expectedUserId: 'a',
          ),
          throwsStateError,
        );
        final saving = service.updateProfileSettings(
          (current) => current.copyWith(hourFormat: '24h', notifyGoals: false),
        );
        storage.release.complete();
        await Future.wait([loginB, saving]);
        await service.pending;
        final actual = await service.loadProfileSettings();
        expect(
          actual.displayName,
          'Account B',
          reason: 'A new device-preference save must not reintroduce the old account name',
        );
        expect(profiles['b']!['displayName'], 'Account B');
        expect(profiles['a']!['displayName'], 'Account A');
        expect(actual.hourFormat, '24h');
        expect(actual.notifyGoals, isFalse);
        await service.updateProfileSettings(
          (current) => current.copyWith(displayName: 'B explicit edit'),
          expectedUserId: 'b',
        );
        final edited = await service.loadProfileSettings();
        expect(edited.displayName, 'B explicit edit');
        expect(edited.hourFormat, '24h');
        expect(edited.notifyGoals, isFalse);
        expect(profiles['b']!['displayName'], 'B explicit edit');
        await Future.wait([
          service.updateProfileSettings(
            (current) => current.copyWith(notifyFinal: false),
          ),
          service.updateProfileSettings(
            (current) => current.copyWith(notifyKickoff: false),
          ),
        ]);
        final combined = await service.loadProfileSettings();
        expect(combined.notifyFinal, isFalse);
        expect(combined.notifyKickoff, isFalse);
        expect(combined.displayName, 'B explicit edit');
        expect(combined.hourFormat, '24h');
        if (afterConsumption) {
          storage.holdRead = true;
          final editing = service.updateProfileSettings(
            (current) => current.copyWith(displayName: 'B superseded edit'),
            expectedUserId: 'b',
          );
          final rejected = expectLater(editing, throwsStateError);
          await storage.readEntered.future;
          final leftB = service.accountChanges.firstWhere((uid) => uid == null);
          final a = service.signIn('a@example.test', 'synthetic-password');
          await leftB;
          storage.readRelease.complete();
          await Future.wait([a, rejected]);
          await service.pending;
          expect(service.userId, 'a');
          expect(
            (await service.loadProfileSettings()).displayName,
            'Account A',
          );
          expect(profiles['a']!['displayName'], 'Account A');
          expect(profiles['b']!['displayName'], 'B explicit edit');
        }
      },
    );
  }
}

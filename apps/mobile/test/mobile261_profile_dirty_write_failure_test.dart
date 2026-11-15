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

class _WriteFailure extends FlutterSecureStorage {
  _WriteFailure(this.stage);
  final String stage;
  bool failed = false;
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
    final matches = switch (stage) {
      'intent-flag' => key == 'futbeat.profile.dirty' && value == 'true',
      'profile-blob' => key == 'futbeat.profile.settings',
      'ack-flag' => key == 'futbeat.profile.dirty' && value == 'false',
      _ => false,
    };
    if (matches && !failed) {
      failed = true;
      throw PlatformException(code: 'synthetic-profile-write-failure');
    }
    return super.write(
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
  _Service(AppDatabase db, Dio dio, this.testStorage, DateTime Function() clock)
    : super(
        const LiveRealtimeConfig(
          supabaseUrl: 'https://fixture.invalid',
          publicKey: 'synthetic',
        ),
        db,
        _Tokens(),
        dio: dio,
        clock: clock,
        pushConfigured: false,
      );
  final FlutterSecureStorage testStorage;
  @override
  FlutterSecureStorage get storage => testStorage;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final stage in ['intent-flag', 'profile-blob', 'ack-flag']) {
    test(
      'profile $stage failure cannot leave a persisted edit falsely clean',
      () async {
        const old = UserProfileSettings(hourFormat: '12h');
        const next = UserProfileSettings(hourFormat: '24h');
        FlutterSecureStorage.setMockInitialValues({
          'futbeat.profile.settings': jsonEncode(old.toJson()),
          'futbeat.profile.dirty': 'false',
          PushService.pushedKey('synthetic-A'): '[]',
        });
        final db = AppDatabase(NativeDatabase.memory());
        final dio = Dio();
        var now = DateTime.utc(2026, 11, 3, 20);
        var cloud = old.toJson();
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              if (request.path.endsWith('futbeat_sync_user_profile_v3')) {
                cloud = Map<String, dynamic>.from(
                  request.data['p_profile'] as Map,
                );
              }
              handler.resolve(
                Response(
                  requestOptions: request,
                  data: request.path.endsWith('futbeat_read_user_profile')
                      ? {'preferences': cloud, 'follows': <dynamic>[]}
                      : <String, dynamic>{},
                ),
              );
            },
          ),
        );
        final storage = _WriteFailure(stage);
        final service = _Service(db, dio, storage, () => now)
          ..session = {
            'access_token': 'synthetic-A',
            'refresh_token': 'synthetic-refresh',
            'expires_at':
                now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
                1000,
            'user': {'id': 'synthetic-A'},
          };
        addTearDown(() async {
          service.dispose();
          await db.close();
        });
        await expectLater(
          service.saveProfileSettings(next),
          throwsA(isA<PlatformException>()),
        );
        expect(storage.failed, isTrue);
        final beforeResume = await service.loadProfileSettings();
        await service.resume();
        expect(
          (await service.loadProfileSettings()).hourFormat,
          beforeResume.hourFormat,
          reason: 'a persisted partial edit must not be mistaken for a clean cloud-owned value',
        );
        // Retry remains available after either storage stage or ACK failed.
        await service.saveProfileSettings(next);
        now = now.add(const Duration(minutes: 6));
        await service.resume();
        expect((await service.loadProfileSettings()).hourFormat, '24h');
        expect(cloud['hourFormat'], '24h');
        expect(await storage.read(key: 'futbeat.profile.dirty'), 'false');
      },
    );
  }
}

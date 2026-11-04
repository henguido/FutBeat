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

class _FlagReadFailure extends FlutterSecureStorage {
  _FlagReadFailure(this.failedKey);
  final String failedKey;
  bool failed = false;
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
    if (key == failedKey && !failed) {
      failed = true;
      throw PlatformException(code: 'synthetic-dirty-flag-locked');
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
  for (final failedKey in [
    'futbeat.profile.dirty',
    'futbeat.country.selected.dirty',
    'futbeat.country.detected.dirty',
    'futbeat.country.dirty',
  ]) {
    test(
      'unreadable $failedKey cannot authorize cloud overwrite of local choices',
      () async {
        final profileFailure = failedKey == 'futbeat.profile.dirty';
        final legacyFailure = failedKey == 'futbeat.country.dirty';
        FlutterSecureStorage.setMockInitialValues({
          'futbeat.profile.settings': jsonEncode(
            const UserProfileSettings(hourFormat: '24h').toJson(),
          ),
          'futbeat.profile.dirty': profileFailure ? 'true' : 'false',
          'futbeat.country.dirty': 'true',
          if (!legacyFailure) ...{
            'futbeat.country.selected.dirty': 'true',
            'futbeat.country.detected.dirty': 'true',
          },
          PushService.pushedKey('synthetic-A'): '[]',
        });
        final db = AppDatabase(NativeDatabase.memory());
        await db.savePreference(detectedCountry: 'CR', selectedCountry: 'MX');
        final dio = Dio();
        final calls = <RequestOptions>[];
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              calls.add(request);
              handler.resolve(
                Response(
                  requestOptions: request,
                  data: request.path.endsWith('futbeat_read_user_profile')
                      ? {
                          'preferences': {
                            'hourFormat': profileFailure ? '12h' : '24h',
                            'detectedCountry': 'US',
                            'selectedCountry': 'US',
                          },
                          'follows': <dynamic>[],
                        }
                      : <String, dynamic>{},
                ),
              );
            },
          ),
        );
        final storage = _FlagReadFailure(failedKey);
        final service = _Service(db, dio, storage)
          ..session = {
            'access_token': 'synthetic-A',
            'refresh_token': 'synthetic-refresh',
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
        await service.resume();
        expect(storage.failed, isTrue);
        final local = await db.watchPreference().first;
        if (profileFailure) {
          expect((await service.loadProfileSettings()).hourFormat, '24h');
        } else {
          expect(local.selectedCountry, 'MX');
          expect(local.detectedCountry, 'CR');
        }
        // A transient flag read error must not poison the existing resume loop.
        await service.resume();
        if (profileFailure) {
          expect((await service.loadProfileSettings()).hourFormat, '24h');
          expect(
            calls
                .where((r) => r.path.endsWith('futbeat_sync_user_profile_v3'))
                .last
                .data['p_profile']['hourFormat'],
            '24h',
          );
        } else {
          final retried = await db.watchPreference().first;
          expect(retried.selectedCountry, 'MX');
          expect(retried.detectedCountry, 'CR');
          final countryCall = calls
              .where(
                (r) => r.path.endsWith('futbeat_sync_user_preference_fields'),
              )
              .last;
          expect(countryCall.data['p_selected'], 'MX');
          expect(countryCall.data['p_detected'], 'CR');
        }
      },
    );
  }
}

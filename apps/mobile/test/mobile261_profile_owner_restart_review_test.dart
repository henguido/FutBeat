import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  for (final mode in ['file-reopen']) {
    test('pending A profile owner survives B logout and fresh SQLite/service restart', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'futbeat-profile-owner261-',
      );
      final file = File('${directory.path}/preferences.sqlite');
      var db = AppDatabase(NativeDatabase(file));
      final profiles = <String, Map<String, dynamic>>{
        'a': UserProfileSettings(displayName: null, hourFormat: '12h').toJson(),
        'b': UserProfileSettings(
          displayName: mode.startsWith('default') ? null : 'Account B',
          hourFormat: '12h',
        ).toJson(),
      };
      final countries = <String, String?>{'a': 'US', 'b': 'US'};
      var rejectProfileWrites = false;
      Dio makeDio() => Dio()
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
                    'selectedCountry': countries[uid],
                    'detectedCountry': 'US',
                  },
                  'follows': <Object>[],
                };
              } else if (r.path.endsWith(
                'futbeat_sync_user_preference_fields',
              )) {
                final fields = r.data as Map;
                if (fields['p_update_selected'] == true) {
                  countries[uid] = fields['p_selected'] as String?;
                }
              } else if (r.path.endsWith('futbeat_sync_user_profile_v3')) {
                if (rejectProfileWrites || uid == 'b') {
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
      var dio = makeDio();
      const storage = FlutterSecureStorage();
      var service = _Service(db, dio, storage);
      addTearDown(() async {
        service.dispose();
        await service.pending;
        await service.signOutCleanup;
        dio.close(force: true);
        await db.close();
        await directory.delete(recursive: true);
      });
      await service.signIn('a@example.test', 'synthetic-password');
      await service.pending;
      if (true) {
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
      await db.saveSelectedCountry('MX');
      await service.syncCountries(null, 'MX', updateDetected: false);
      expect(
        countries['a'],
        'MX',
        reason: 'A country ACK is persisted by the mock server before logout',
      );
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
      await service.signIn('b@example.test', 'synthetic-password');
      await service.pending;
      expect(service.userId, 'b');
      await service.signOut();
      final marker = jsonDecode(
        (await storage.read(key: PushService.leftoverKey))!,
      ) as Map;
      expect(marker['userId'], 'b');
      expect(marker['profileUserId'], 'a');
      expect(marker['profileDisplayName'], 'Account A');
      service.dispose();
      await service.pending;
      await service.signOutCleanup;
      dio.close(force: true);
      await db.close();
      db = AppDatabase(NativeDatabase(file));
      dio = makeDio();
      service = _Service(db, dio, storage);
      await service.pending;
      expect(service.authenticated, isFalse);
      await service.signIn('a@example.test', 'synthetic-password');
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

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in ['profile-failure', 'first-follows-failure']) {
    test(
      'retained owner must preserve explicit B follow after $mode',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        const storage = FlutterSecureStorage();
        final db = AppDatabase(NativeDatabase.memory());
        final follows = <String, Set<String>>{
          'a': {'team:fb_team_x'},
          'b': {'team:fb_team_b'},
        };
        var failProfileB = mode == 'profile-failure';
        var failFollowsB = mode == 'first-follows-failure';
        var failedFollowsB = false;
        var failedProfileB = false;
        final dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (r, h) {
                final uid = '${r.headers['Authorization']}'.endsWith('access-b')
                    ? 'b'
                    : 'a';
                Object? data;
                if (r.path.contains('/auth/v1/token')) {
                  final target = (r.data as Map)['email'] == 'b@example.test'
                      ? 'b'
                      : 'a';
                  data = {
                    'access_token': 'access-$target',
                    'refresh_token': 'refresh-$target',
                    'user': {'id': target},
                  };
                } else if (r.path.endsWith('futbeat_read_user_profile')) {
                  data = {
                    'preferences': const UserProfileSettings().toJson(),
                    'follows': [
                      for (final key in follows[uid]!)
                        {
                          'type': key.split(':').first,
                          'id': key.split(':').last,
                        },
                    ],
                  };
                } else if (r.path.endsWith('futbeat_sync_push_follows')) {
                  if (uid == 'b' && failFollowsB) {
                    failFollowsB = false;
                    failedFollowsB = true;
                    h.reject(
                      DioException(
                        requestOptions: r,
                        type: DioExceptionType.connectionError,
                      ),
                    );
                    return;
                  }
                  follows[uid] = {
                    for (final item in (r.data as Map)['p_follows'] as List)
                      '${item['type']}:${item['id']}',
                  };
                } else if (uid == 'b' &&
                    r.path.endsWith('futbeat_sync_user_profile_v3') &&
                    failProfileB) {
                  failedProfileB = true;
                  h.reject(
                    DioException(
                      requestOptions: r,
                      type: DioExceptionType.connectionError,
                    ),
                  );
                  return;
                }
                h.resolve(
                  Response(requestOptions: r, statusCode: 200, data: data),
                );
              },
            ),
          );
        final service = PushService(
          const LiveRealtimeConfig(
            supabaseUrl: 'https://fixture.invalid',
            publicKey: 'synthetic',
          ),
          db,
          _Tokens(),
          dio: dio,
          pushConfigured: false,
        );
        addTearDown(() async {
          service.dispose();
          await service.pending;
          await service.signOutCleanup;
          dio.close(force: true);
          await db.close();
        });
        await service.signIn('a@example.test', 'synthetic-password');
        await service.pending;
        await service.signOut();
        await service.saveProfileSettings(
          const UserProfileSettings(hourFormat: '24h'),
        );
        await service.signIn('b@example.test', 'synthetic-password');
        await service.pending;
        expect(
          failedProfileB,
          mode == 'profile-failure',
          reason:
              'Precondition: B profile write failed independently of follows',
        );
        expect(failedFollowsB, mode == 'first-follows-failure');
        if (mode == 'first-follows-failure') {
          expect(
            await storage.read(key: PushService.pushedKey('b')),
            isNull,
            reason: 'First B follows upload failed before persisting P_B',
          );
        }
        expect(follows['b'], {'team:fb_team_b'});
        expect(
          await db.watchFollows().first,
          {'team:fb_team_b'},
          reason: 'Initial account separation completed locally before explicit new X follow',
        );
        final marker = await storage.read(key: PushService.leftoverKey);
        expect(
          marker,
          isNotNull,
          reason:
              'Profile ownership retained until failed profile step recovers',
        );
        expect((jsonDecode(marker!) as Map)['userId'], 'a');
        await db.addFollows({'team:fb_team_x'});
        final selected = await db.watchFollows().first;
        expect(selected, contains('team:fb_team_x'));
        await service.syncFollows(selected);
        await service.pending;
        expect(
          await db.watchFollows().first,
          contains('team:fb_team_x'),
          reason:
              'B explicit new follow must survive a retained A profile marker',
        );
        expect(follows['b'], contains('team:fb_team_x'));
        expect(follows['a'], {'team:fb_team_x'});
        failProfileB = false;
      },
    );
  }
}

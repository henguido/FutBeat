import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/push.dart';

class _NoTokens implements PushTokenSource {
  @override
  Future<String?> currentToken() async => null;
  @override
  Future<String?> requestToken() async => null;
  @override
  Stream<String> get rotations => const Stream.empty();
}

Map<String, dynamic> _session(String id) => {
  'access_token': 'synthetic-access-$id',
  'refresh_token': 'synthetic-refresh-$id',
  'user': {'id': id},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase database;
  late Dio dio;
  late PushService service;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    database = AppDatabase(NativeDatabase.memory());
    dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
    service = PushService(
      const LiveRealtimeConfig(
        supabaseUrl: 'https://fixture.invalid',
        publicKey: 'synthetic-local-key',
      ),
      database,
      _NoTokens(),
      dio: dio,
      pushConfigured: false,
    )..session = _session('first');
  });
  tearDown(() async {
    service.dispose();
    dio.close(force: true);
    await database.close();
  });

  test(
    'older success cannot clear dirty after a newer edit fails to sync',
    () async {
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      var writes = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) async {
            final sequence = ++writes;
            if (sequence == 1) {
              firstStarted.complete();
              await releaseFirst.future;
              handler.resolve(
                Response(requestOptions: request, data: <String, dynamic>{}),
              );
            } else {
              handler.reject(
                DioException(
                  requestOptions: request,
                  response: Response(requestOptions: request, statusCode: 503),
                  type: DioExceptionType.badResponse,
                ),
              );
            }
          },
        ),
      );
      final old = service.saveProfileSettings(
        const UserProfileSettings(hourFormat: '12h'),
      );
      await firstStarted.future;
      await expectLater(
        service.saveProfileSettings(
          const UserProfileSettings(hourFormat: '24h'),
        ),
        throwsA(isA<DioException>()),
      );
      releaseFirst.complete();
      await old;
      expect((await service.loadProfileSettings()).hourFormat, '24h');
      expect(await service.storage.read(key: 'futbeat.profile.dirty'), 'true');
      expect(writes, 2);
    },
  );

  for (final missingRpc in [false, true]) {
    test(
      'late profile ${missingRpc ? 'missing RPC' : 'success'} cannot cross sign-out',
      () async {
        final started = Completer<void>();
        final release = Completer<void>();
        var legacyWrites = 0;
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) async {
              if (request.path.endsWith('futbeat_sync_user_profile_v3')) {
                started.complete();
                await release.future;
                if (missingRpc) {
                  handler.reject(
                    DioException(
                      requestOptions: request,
                      response: Response(
                        requestOptions: request,
                        statusCode: 404,
                        data: {'code': 'PGRST202'},
                      ),
                      type: DioExceptionType.badResponse,
                    ),
                  );
                  return;
                }
              }
              if (request.path.endsWith('futbeat_sync_user_profile_v2'))
                legacyWrites++;
              handler.resolve(
                Response(requestOptions: request, data: <String, dynamic>{}),
              );
            },
          ),
        );
        final old = service.saveProfileSettings(
          const UserProfileSettings(hourFormat: '12h'),
        );
        await started.future;
        await service.signOut();
        await service.signOutCleanup;
        // A real guest edit after sign-out remains pending for the next link.
        await service.saveProfileSettings(
          const UserProfileSettings(hourFormat: '24h'),
        );
        service.session = _session('second');
        release.complete();
        await old;
        expect(service.userId, 'second');
        expect((await service.loadProfileSettings()).hourFormat, '24h');
        expect(
          await service.storage.read(key: 'futbeat.profile.dirty'),
          'true',
        );
        expect(legacyWrites, 0);
      },
    );
  }
}

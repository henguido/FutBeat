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

Map<String, dynamic> session(String id) => {
  'access_token': 'synthetic-$id',
  'refresh_token': 'synthetic-refresh-$id',
  'user': {'id': id},
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final phase in ['queued', 'success', 'failure']) {
    test('deletion intent A cannot affect later account B ($phase)', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio();
      final service =
          PushService(
              const LiveRealtimeConfig(
                supabaseUrl: 'https://fixture.invalid',
                publicKey: 'synthetic-public',
              ),
              db,
              _Tokens(),
              dio: dio,
              pushConfigured: false,
            )
            ..session = session('A')
            ..enabled = true;
      addTearDown(() async {
        service.dispose();
        await db.close();
      });
      final requestStarted = Completer<void>();
      final releaseResponse = Completer<void>();
      final queued = Completer<void>();
      final deletionCalls = <RequestOptions>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) async {
            if (request.path.endsWith('futbeat-delete-account')) {
              deletionCalls.add(request);
              if (!requestStarted.isCompleted) requestStarted.complete();
              if (phase != 'queued') await releaseResponse.future;
              if (phase == 'failure') {
                handler.reject(
                  DioException(
                    requestOptions: request,
                    response: Response(
                      requestOptions: request,
                      statusCode: 503,
                    ),
                    type: DioExceptionType.badResponse,
                  ),
                );
                return;
              }
              handler.resolve(
                Response(requestOptions: request, data: {'deleted': true}),
              );
              return;
            }
            handler.resolve(
              Response(requestOptions: request, data: <String, dynamic>{}),
            );
          },
        ),
      );
      if (phase == 'queued') service.pending = queued.future;
      final deleting = service.deleteAccount().then(
        (_) => true,
        onError: (_) => false,
      );
      if (phase == 'queued') {
        await Future<void>.delayed(Duration.zero);
        expect(deletionCalls, isEmpty);
      } else {
        await requestStarted.future;
        expect(
          deletionCalls.single.headers['Authorization'],
          'Bearer synthetic-A',
        );
      }
      await service.signOut();
      await service.signOutCleanup;
      service.session = session('B');
      await service.storage.write(
        key: 'futbeat.push.session',
        value: jsonEncode(session('B')),
      );
      await service.saveProfileSettings(
        const UserProfileSettings(
          displayName: 'Persona sintética B',
          hourFormat: '24h',
        ),
      );
      expect(service.enabled, isFalse);
      if (phase == 'queued') {
        queued.complete();
      } else {
        releaseResponse.complete();
      }
      expect(
        await deleting,
        isFalse,
        reason: 'stale intent is not a successful deletion of current account',
      );
      expect(service.userId, 'B');
      expect(
        service.enabled,
        isFalse,
        reason: 'A failure must not enable push for B',
      );
      expect((await service.loadProfileSettings()).hourFormat, '24h');
      expect(
        jsonDecode(
          (await service.storage.read(key: 'futbeat.push.session'))!,
        )['user']['id'],
        'B',
      );
      if (phase == 'queued') expect(deletionCalls, isEmpty);
    });
  }
}

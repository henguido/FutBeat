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
  const storage = FlutterSecureStorage();
  const receiptKey = 'futbeat.account.deletionReceipt';
  test(
    'R05 recovers a committed deletion after losing the POST response',
    () async {
      const sessionKey = 'futbeat.push.session';
      const session = {
        'access_token': 'synthetic-token',
        'user': {'id': 'test-user'},
      };
      FlutterSecureStorage.setMockInitialValues({
        sessionKey: jsonEncode(session),
      });
      final db = AppDatabase(NativeDatabase.memory());
      final postIds = <String>[];
      final lookupIds = <String>[];
      var online = true;
      final interceptor = InterceptorsWrapper(
        onRequest: (request, handler) async {
          if (request.path.endsWith('/futbeat-delete-account')) {
            final id = request.headers['X-FutBeat-Deletion-Id'] as String;
            final stored = jsonDecode((await storage.read(key: receiptKey))!);
            expect(stored['deletionId'], id);
            postIds.add(
              id,
            ); // The test server commits before losing the response.
            online = false;
          } else if (request.path.endsWith(
            '/futbeat_account_deletion_status',
          )) {
            lookupIds.add((request.data as Map)['p_deletion_id'] as String);
            if (online) {
              handler.resolve(
                Response(
                  requestOptions: request,
                  statusCode: 200,
                  data: {'status': 'deleted'},
                ),
              );
              return;
            }
          } else if (online) {
            fail('Unexpected online request: ${request.path}');
          }
          handler.reject(
            DioException(
              requestOptions: request,
              type: DioExceptionType.connectionError,
            ),
          );
        },
      );
      PushService createService() => PushService(
        const LiveRealtimeConfig(
          supabaseUrl: 'https://fixture.invalid',
          publicKey: 'synthetic',
        ),
        db,
        _Tokens(),
        dio: Dio()..interceptors.add(interceptor),
        secureStorage: storage,
        deletionReceiptsEnabled: true,
        pushConfigured: false,
      );
      var service = createService()..session = Map<String, dynamic>.of(session);
      addTearDown(() async {
        service.dispose();
        await db.close();
      });
      await expectLater(
        service.deleteAccount(),
        throwsA(isA<AccountDeletionUnconfirmed>()),
      );
      expect(service.userId, 'test-user');
      final retainedReceipt = await storage.read(key: receiptKey);
      expect(retainedReceipt, isNotNull);
      service.dispose();
      service = createService();
      await service.restore();
      expect(await storage.read(key: receiptKey), retainedReceipt);
      service.dispose();
      online = true;
      service = createService();
      await service.restore();
      expect(postIds, hasLength(1));
      expect(lookupIds, hasLength(3));
      expect(lookupIds, everyElement(postIds.single));
      expect(service.authenticated, isFalse);
      expect(await storage.read(key: receiptKey), isNull);
      expect(await storage.read(key: sessionKey), isNull);
    },
  );
  for (final (code, status) in [
    (200, 'unknown'),
    (401, 'pending'),
    (401, 'unknown'),
    (202, 'pending'),
    (503, 'unknown'),
  ]) {
    test('R05 keeps session and same receipt on $code / $status', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio();
      final ids = <String>[];
      final lookups = <String>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (r, h) async {
            if (r.path.endsWith('/futbeat-delete-account')) {
              final receipt = jsonDecode(
                (await storage.read(key: receiptKey))!,
              );
              final id = r.headers['X-FutBeat-Deletion-Id'] as String;
              expect(receipt['uid'], 'test-user');
              expect(receipt['deletionId'], id);
              expect(
                id,
                matches(
                  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
                ),
              );
              ids.add(id);
              h.resolve(
                Response(
                  requestOptions: r,
                  statusCode: code,
                  data: switch (code) {
                    200 => {'deleted': true, 'deletionId': 'wrong-receipt'},
                    202 => {
                      'deleted': false,
                      'pending': true,
                      'deletionId': id,
                      'code': 'DELETION_PENDING',
                    },
                    503 => {'code': 'RECEIPT_UNAVAILABLE'},
                    _ => null,
                  },
                ),
              );
            } else if (r.path.endsWith('/futbeat_account_deletion_status')) {
              expect(r.method, 'POST');
              expect(
                r.headers.keys.map((k) => k.toLowerCase()),
                isNot(contains('authorization')),
              );
              lookups.add((r.data as Map)['p_deletion_id'] as String);
              h.resolve(
                Response(
                  requestOptions: r,
                  statusCode: 200,
                  data: {'status': status},
                ),
              );
            } else {
              h.resolve(
                Response(
                  requestOptions: r,
                  statusCode: 200,
                  data: <String, dynamic>{},
                ),
              );
            }
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
        secureStorage: storage,
        deletionReceiptsEnabled: true,
        pushConfigured: false,
      );
      addTearDown(() async {
        service.dispose();
        await db.close();
      });
      service.session = {
        'access_token': 'synthetic-token',
        'user': {'id': 'test-user', 'is_anonymous': true},
      };
      await expectLater(service.deleteAccount(), throwsStateError);
      expect(ids, isEmpty);
      service.session = {
        'access_token': 'synthetic-token',
        'user': {'id': 'test-user'},
      };
      for (var i = 0; i < 2; i++) {
        await expectLater(
          service.deleteAccount(),
          throwsA(
            isA<AccountDeletionUnconfirmed>().having(
              (e) => e.status.name,
              'status',
              status,
            ),
          ),
        );
      }
      expect(service.userId, 'test-user');
      expect(ids, hasLength(2));
      expect(ids.toSet(), hasLength(1));
      expect(lookups, everyElement(ids.first));
      expect(await storage.read(key: receiptKey), isNotNull);
    });
  }
  test(
    'R05 restores a deleted receipt before refreshing the old session',
    () async {
      const id = 'b8fcf08c-6895-4623-8f98-27cc4ea4e4f2';
      FlutterSecureStorage.setMockInitialValues({
        receiptKey: jsonEncode({'uid': 'test-user', 'deletionId': id}),
        'futbeat.push.session': jsonEncode({
          'access_token': 'synthetic-token',
          'refresh_token': 'synthetic-refresh',
          'user': {'id': 'test-user'},
        }),
      });
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio();
      final requests = <String>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (r, h) {
            requests.add(r.path);
            h.resolve(
              Response(
                requestOptions: r,
                statusCode: 200,
                data: {'status': 'deleted'},
              ),
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
        secureStorage: storage,
        deletionReceiptsEnabled: true,
        pushConfigured: false,
      );
      addTearDown(() async {
        service.dispose();
        await db.close();
      });
      await service.restore();
      expect(requests, [
        'https://fixture.invalid/rest/v1/rpc/futbeat_account_deletion_status',
      ]);
      expect(service.authenticated, isFalse);
      expect(await storage.read(key: receiptKey), isNull);
      expect(await storage.read(key: 'futbeat.push.session'), isNull);
    },
  );
}

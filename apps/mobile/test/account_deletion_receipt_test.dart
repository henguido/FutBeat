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
  for (final status in ['pending', 'unknown']) {
    test('R05 keeps session and same receipt on 401 / $status', () async {
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
              h.resolve(Response(requestOptions: r, statusCode: 401));
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

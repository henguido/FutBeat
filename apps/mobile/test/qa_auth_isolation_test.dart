import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/push.dart';

class NoTokens implements PushTokenSource {
  @override
  Future<String?> currentToken() async => null;
  @override
  Future<String?> requestToken() async => null;
  @override
  Stream<String> get rotations => const Stream.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('G1 QA never restores or transmits Play production session or pending email', () async {
    final production = jsonEncode({
      'access_token': 'synthetic-production',
      'refresh_token': 'synthetic-refresh',
      'user': {'id': 'production-user'},
    });
    FlutterSecureStorage.setMockInitialValues({
      'futbeat.push.session': production,
      'futbeat.auth.pendingConfirmationEmail': 'production@example.test',
    });
    final db = AppDatabase(NativeDatabase.memory());
    final dio = Dio();
    var requests = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (r, h) {
          requests++;
          h.resolve(
            Response(
              requestOptions: r,
              statusCode: 200,
              data: <String, dynamic>{},
            ),
          );
        },
      ),
    );
    final qa = PushService(
      const LiveRealtimeConfig(
        supabaseUrl: 'https://wctxcnqcblgewaznxrqh.supabase.co',
        publicKey: 'synthetic-qa-public',
      ),
      db,
      NoTokens(),
      dio: dio,
      pushConfigured: false,
    );
    addTearDown(() async {
      qa.dispose();
      await db.close();
    });
    await qa.restore();
    expect(qa.authenticated, false);
    expect(qa.pendingConfirmationEmail, null);
    expect(requests, 0);
    await qa.storage.write(
      key: 'futbeat.profile.settings',
      value: '{"displayName":"production-profile"}',
    );
    expect((await qa.loadProfileSettings()).displayName, null);
    await qa.updateProfileSettings(
      (p) => p.copyWith(displayName: 'qa-profile'),
    );
    expect((await qa.loadProfileSettings()).displayName, 'qa-profile');
    expect(
      await qa.storage.read(key: 'futbeat.profile.settings'),
      '{"displayName":"production-profile"}',
    );
    expect(
      localDatabaseName('https://wctxcnqcblgewaznxrqh.supabase.co'),
      'futbeat_g1_qa',
    );
    expect(
      localDatabaseName('https://izlmruqawgagwdcsjhte.supabase.co'),
      'futbeat',
    );
    expect(await qa.storage.read(key: 'futbeat.push.session'), production);
    expect(qa.sessionStorageKey, isNot('futbeat.push.session'));
    await qa.storage.write(
      key: qa.sessionStorageKey,
      value: 'synthetic-qa-record',
    );
    expect(await qa.storage.read(key: 'futbeat.push.session'), production);
    final prod = PushService(
      const LiveRealtimeConfig(
        supabaseUrl: 'https://izlmruqawgagwdcsjhte.supabase.co',
        publicKey: 'synthetic-prod-public',
      ),
      db,
      NoTokens(),
      pushConfigured: false,
    );
    addTearDown(prod.dispose);
    expect(
      prod.sessionStorageKey,
      'futbeat.push.session',
    ); // Play16 compatibility
  });
}

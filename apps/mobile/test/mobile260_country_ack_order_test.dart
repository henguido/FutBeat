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

class _Service extends PushService {
  _Service(AppDatabase database, Dio dio, this.testStorage)
    : super(
        const LiveRealtimeConfig(
          supabaseUrl: 'https://fixture.invalid',
          publicKey: 'synthetic-public',
        ),
        database,
        _Tokens(),
        dio: dio,
        pushConfigured: false,
      );
  final FlutterSecureStorage testStorage;
  @override
  FlutterSecureStorage get storage => testStorage;
}

class _HeldCountryAck extends FlutterSecureStorage {
  final captured = Completer<void>();
  final release = Completer<void>();
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
    if (key == 'futbeat.country.selected.dirty' &&
        value == 'false' &&
        !captured.isCompleted) {
      captured.complete();
      await release.future;
    }
    await super.write(
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'late country ACK cannot erase a newer unsynced country intent',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio();
      final storage = _HeldCountryAck();
      final service = _Service(db, dio, storage)
        ..session = {
          'access_token': 'synthetic-A',
          'user': {'id': 'synthetic-A'},
        };
      addTearDown(() async {
        service.dispose();
        await db.close();
      });
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            handler.resolve(
              Response(requestOptions: request, data: <String, dynamic>{}),
            );
          },
        ),
      );
      await db.saveSelectedCountry('MX');
      final old = service.syncCountries(null, 'MX', updateDetected: false);
      await storage.captured.future;
      await db.saveSelectedCountry('CR');
      final latest = service.markSelectedCountryDirty();
      await Future<void>.delayed(Duration.zero);
      storage.release.complete();
      await Future.wait([old, latest]);
      expect((await db.watchPreference().first).selectedCountry, 'CR');
      expect(await storage.read(key: 'futbeat.country.selected.dirty'), 'true');
      expect(await storage.read(key: 'futbeat.country.dirty'), 'true');
    },
  );
}

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/passive_preview_transport.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/push.dart';

import 'support/install_secure_storage.dart';

class _NoPush implements PushTokenSource {
  @override
  Future<String?> currentToken() async => null;
  @override
  Future<String?> requestToken() async => null;
  @override
  Stream<String> get rotations => const Stream.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'common production config wires the existing service to bounded reads',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final authDio = Dio();
      final service = PushService(
        LiveRealtimeConfig.fromEnvironment(),
        db,
        _NoPush(),
        dio: authDio,
        secureStorage: InstallSecureStorage(),
        userSessionAccess: true,
        pushConfigured: false,
      );
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          pushServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(() async {
        container.dispose();
        service.dispose();
        await service.pending;
        authDio.close(force: true);
        await db.close();
      });
      final repository = container.read(repositoryProvider) as ApiRepository;
      expect(repository.storedReadsOnly, isTrue);
      final transport = repository.dio.interceptors
          .whereType<PassivePreviewTransport>()
          .single;
      expect(transport.usesUserSession, isTrue);
      expect(transport.sessionLimit, 30);
      expect(transport.minuteLimit, 8);
      expect(transport.concurrentLimit, 2);
      expect(
        repository.dio.options.baseUrl,
        'https://fixture.invalid/functions/v1/futbeat-api',
      );
      expect(
        repository.dio.options.headers.containsKey('Authorization'),
        isFalse,
      );
      expect(container.read(liveRealtimeConfigProvider).isConfigured, isTrue);
      expect(
        container.read(liveRealtimeClientProvider).config.isConfigured,
        isFalse,
      );
      expect(service.registered, isFalse);
    },
    skip: !userSessionAccessEnabled,
  );
}

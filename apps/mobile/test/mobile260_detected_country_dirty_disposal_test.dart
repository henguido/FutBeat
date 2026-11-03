import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/push.dart';

class _NoTokens implements PushTokenSource {
  @override
  Future<String?> currentToken() async => null;
  @override
  Future<String?> requestToken() async => null;
  @override
  Stream<String> get rotations => const Stream.empty();
}

class _CommittedCountryDatabase extends AppDatabase {
  _CommittedCountryDatabase() : super(NativeDatabase.memory());
  final committed = Completer<void>();
  final release = Completer<void>();
  int writes = 0;
  @override
  Future<void> saveDetectedCountry(String? value) async {
    writes++;
    await super.saveDetectedCountry(value);
    if (!committed.isCompleted) {
      committed.complete();
      await release.future;
    }
  }
}

class _ObservedCountryService extends PushService {
  _ObservedCountryService(AppDatabase db, Dio dio)
    : super(
        const LiveRealtimeConfig(supabaseUrl: '', publicKey: ''),
        db,
        _NoTokens(),
        dio: dio,
        pushConfigured: false,
      );
  final marked = Completer<void>();
  @override
  Future<void> markDetectedCountryDirty() async {
    await super.markDetectedCountryDirty();
    if (!marked.isCompleted) marked.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'committed guest region remains dirty after preference provider disposal',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final db = _CommittedCountryDatabase();
      final dio = Dio();
      final service = _ObservedCountryService(db, dio);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          pushServiceProvider.overrideWithValue(service),
          detectedCountryProvider.overrideWithValue('MX'),
        ],
      );
      addTearDown(() async {
        if (!db.release.isCompleted) db.release.complete();
        container.dispose();
        service.dispose();
        dio.close(force: true);
        await db.close();
      });
      await db.savePreference(detectedCountry: 'CR');
      final listener = container.listen(preferenceProvider, (_, _) {});
      await db.committed.future.timeout(const Duration(seconds: 3));
      listener.close();
      container.invalidate(preferenceProvider);
      await container.pump();
      db.release.complete();
      await service.marked.future.timeout(const Duration(seconds: 3));
      // A later subscriber sees the already committed country and will not
      // mark it dirty again. The original operation must preserve the marker.
      final nextListener = container.listen(preferenceProvider, (_, _) {});
      addTearDown(nextListener.close);
      final next = await container.read(preferenceProvider.future);
      expect(next.detectedCountry, 'MX');
      expect(db.writes, 1);
      expect(
        await service.storage.read(key: 'futbeat.country.detected.dirty'),
        'true',
      );
    },
  );
}

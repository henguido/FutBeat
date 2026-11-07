import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

class _BlockedCountryWrite extends AppDatabase {
  _BlockedCountryWrite() : super(NativeDatabase.memory());

  final committed = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> saveDetectedCountry(String? detectedCountry) async {
    await super.saveDetectedCountry(detectedCountry);
    committed.complete();
    await release.future;
  }
}

class _ObservedAccount extends PushService {
  _ObservedAccount(AppDatabase db)
    : super(
        const LiveRealtimeConfig(supabaseUrl: '', publicKey: ''),
        db,
        _NoTokens(),
        pushConfigured: false,
      );

  int dirtyWrites = 0;
  int syncs = 0;

  @override
  Future<void> markDetectedCountryDirty() async {
    dirtyWrites++;
  }

  @override
  Future<void> syncCountries(
    String? detected,
    String? selected, {
    bool updateDetected = true,
    bool updateSelected = true,
  }) async {
    syncs++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('cached startup does not wait for authenticated country sync', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final db = AppDatabase(NativeDatabase.memory());
    final requestStarted = Completer<RequestOptions>();
    final releaseRequest = Completer<void>();
    final accountDio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) async {
            requestStarted.complete(request);
            await releaseRequest.future;
            handler.reject(
              DioException(
                requestOptions: request,
                type: DioExceptionType.connectionError,
              ),
            );
          },
        ),
      );
    final service =
        PushService(
            const LiveRealtimeConfig(
              supabaseUrl: 'https://example.invalid',
              publicKey: 'fixture',
            ),
            db,
            _NoTokens(),
            dio: accountDio,
            pushConfigured: false,
          )
          ..session = {
            'access_token': 'fixture',
            'user': {'id': 'fixture-user'},
          };
    final calendarDio = Dio(BaseOptions(baseUrl: 'https://example.invalid'));
    var calendarRequests = 0;
    calendarDio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          calendarRequests++;
          handler.reject(
            DioException(
              requestOptions: request,
              type: DioExceptionType.connectionError,
            ),
          );
        },
      ),
    );
    final repository = ApiRepository(
      calendarDio,
      db,
      const CalendarCachePolicy(prefetchRadius: 0),
    );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        pushServiceProvider.overrideWithValue(service),
        detectedCountryProvider.overrideWithValue('MX'),
        repositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(() async {
      if (!releaseRequest.isCompleted) releaseRequest.complete();
      try {
        await service.countryPending;
      } catch (_) {
        // Expected offline write failure.
      }
      container.dispose();
      service.dispose();
      calendarDio.close(force: true);
      await db.close();
    });

    await db.savePreference(
      detectedCountry: 'CR',
      selectedCountry: 'CR',
      bootstrapDismissed: true,
    );
    final snapshot = jsonDecode(
      File('assets/demo.snapshot.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    await db.saveCalendarSnapshot(
      '2026-09-15',
      jsonEncode({...snapshot, 'demo': false}),
    );

    // StartupGate watches this provider continuously. A read alone leaves the
    // stream paused when its first asynchronous SQLite read returns.
    final preferences = container.listen(preferenceProvider, (_, _) {});
    addTearDown(preferences.close);
    final local = container.read(preferenceProvider.future);
    final request = await requestStarted.future.timeout(
      const Duration(seconds: 3),
    );
    expect(request.path, endsWith('/futbeat_sync_user_preference_fields'));
    expect(request.data['p_update_selected'], false);

    // StartupGate awaits this first event before showing the calendar. Leave
    // the account request parked to prove it cannot delay the local event.
    final preference = await local.timeout(const Duration(seconds: 3));
    expect(preference.bootstrapDismissed, isTrue);
    expect(preference.detectedCountry, 'MX');
    expect(preference.selectedCountry, 'CR');
    final calendar = calendarSnapshotProvider(DateTime(2026, 9, 15));
    final subscription = container.listen(calendar, (_, _) {});
    addTearDown(subscription.close);
    final first = await container
        .read(calendar.future)
        .timeout(const Duration(seconds: 3));
    expect(first.matches, isNotEmpty);
    expect(releaseRequest.isCompleted, isFalse);
    expect(calendarRequests, 0);
    expect(
      await service.storage.read(key: 'futbeat.country.detected.dirty'),
      'true',
    );
  });

  test(
    'startup country write does not sync into a replacement account',
    () async {
      final db = _BlockedCountryWrite();
      final service = _ObservedAccount(db)
        ..session = {
          'access_token': 'first',
          'user': {'id': 'first'},
        };
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
        await db.close();
      });

      await db.savePreference(detectedCountry: 'CR', bootstrapDismissed: true);
      final preferences = container.listen(preferenceProvider, (_, _) {});
      addTearDown(preferences.close);
      final local = container.read(preferenceProvider.future);
      await db.committed.future.timeout(const Duration(seconds: 3));
      service.session = {
        'access_token': 'second',
        'user': {'id': 'second'},
      };
      db.release.complete();

      final preference = await local.timeout(const Duration(seconds: 3));
      expect(preference.detectedCountry, 'MX');
      expect(service.dirtyWrites, 0);
      expect(service.syncs, 0);
    },
  );
}

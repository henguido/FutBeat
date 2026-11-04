import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/push.dart';

import 'onboarding_test.dart' show pumpOnboarding;

class _MarkerFailure extends PushService {
  _MarkerFailure(AppDatabase database)
    : super(
        const LiveRealtimeConfig(supabaseUrl: '', publicKey: ''),
        database,
        FirebasePushTokens(),
        pushConfigured: false,
      );

  var attempts = 0;

  @override
  Future<void> markSelectedCountryDirty() async {
    if (++attempts == 1) throw StateError('controlled marker write failure');
    await super.markSelectedCountryDirty();
  }
}

class _CountryWriteFailure extends AppDatabase {
  _CountryWriteFailure() : super(NativeDatabase.memory());
  var fail = true;
  @override
  Future<void> saveSelectedCountry(String? selectedCountry) async {
    if (fail) {
      fail = false;
      throw StateError('controlled local preference write failure');
    }
    return super.saveSelectedCountry(selectedCountry);
  }
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('retry repairs the country marker for an already saved choice', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final db = AppDatabase(NativeDatabase.memory());
    final service = _MarkerFailure(db);
    addTearDown(() async {
      service.dispose();
      await db.close();
    });
    await db.savePreference(detectedCountry: 'CR', selectedCountry: null);
    await pumpOnboarding(
      tester,
      database: db,
      livePreference: true,
      pushService: service,
    );
    Future<void> choose() async {
      await tester.tap(find.byKey(const ValueKey('onboarding-country')));
      await _flush(tester);
      await tester.enterText(
        find.byKey(const ValueKey('country-picker-search')),
        'costa',
      );
      await _flush(tester);
      await tester.tap(find.byKey(const ValueKey('country-CR')));
      await _flush(tester);
    }

    const message =
        'No pudimos completar el cambio de país. Inténtalo nuevamente.';
    await choose();
    final saved = await tester.runAsync(() => db.watchPreference().first);
    expect(saved?.selectedCountry, 'CR');
    await _flush(tester);
    expect(service.attempts, 1);
    expect(find.text(message), findsOneWidget);
    await choose();
    await tester.runAsync(() => db.watchPreference().first);
    await _flush(tester);
    expect(service.attempts, 2);
    expect(
      await service.storage.read(key: 'futbeat.country.selected.dirty'),
      'true',
    );
    expect(find.text(message), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  });

  testWidgets('country write failure leaves picker usable for retry', (
    tester,
  ) async {
    final db = _CountryWriteFailure();
    addTearDown(db.close);
    await db.savePreference(detectedCountry: 'CR', selectedCountry: null);
    await pumpOnboarding(tester, database: db, livePreference: true);
    Future<void> choose() async {
      await tester.tap(find.byKey(const ValueKey('onboarding-country')));
      await _flush(tester);
      await tester.enterText(
        find.byKey(const ValueKey('country-picker-search')),
        'costa',
      );
      await _flush(tester);
      await tester.tap(find.byKey(const ValueKey('country-CR')));
      await _flush(tester);
    }

    await choose();
    expect(tester.takeException(), isNull);
    final picker = tester.widget<InkWell>(
      find.byKey(const ValueKey('onboarding-country')),
    );
    expect(picker.onTap, isNotNull);
    expect(
      find.text(
        'No pudimos completar el cambio de país. Inténtalo nuevamente.',
      ),
      findsOneWidget,
    );
    await choose();
    final saved = await tester.runAsync(() => db.watchPreference().first);
    expect(saved?.selectedCountry, 'CR');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  });
}

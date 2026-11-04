import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/push.dart';
import 'package:futbeat/features/profile/personalization_screen.dart';

class _CountryWriteFailure extends AppDatabase {
  _CountryWriteFailure() : super(NativeDatabase.memory());

  var fail = true;

  @override
  Future<void> saveSelectedCountry(String? selectedCountry) async {
    if (fail) {
      fail = false;
      throw StateError('controlled local preference write failure');
    }
    await super.saveSelectedCountry(selectedCountry);
  }
}

void main() {
  testWidgets('Profile keeps country selection usable after SQLite failure', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final db = _CountryWriteFailure();
    addTearDown(db.close);
    await db.savePreference(detectedCountry: 'CR', selectedCountry: 'CR');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          liveRealtimeConfigProvider.overrideWithValue(
            const LiveRealtimeConfig(supabaseUrl: '', publicKey: ''),
          ),
          preferenceProvider.overrideWith(
            (ref) => Stream.value(
              const CountryPreference(
                detectedCountry: 'CR',
                selectedCountry: 'CR',
                bootstrapDismissed: true,
              ),
            ),
          ),
          followsProvider.overrideWith((ref) => Stream.value(const <String>{})),
          profileSettingsProvider.overrideWith(
            (ref) async => const UserProfileSettings(),
          ),
        ],
        child: const MaterialApp(home: PersonalizationScreen()),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> chooseMexico() async {
      await tester.tap(find.text('País'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('country-picker-search')),
        'México',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('country-MX')));
      await tester.pumpAndSettle();
    }

    await chooseMexico();
    expect(tester.takeException(), isNull);
    expect(
      find.text(
        'No pudimos completar el cambio de país. Inténtalo nuevamente.',
      ),
      findsOneWidget,
    );
    final unchanged = await tester.runAsync(() => db.watchPreference().first);
    expect(unchanged?.selectedCountry, 'CR');

    await chooseMexico();
    final updated = await tester.runAsync(() => db.watchPreference().first);
    expect(updated?.selectedCountry, 'MX');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

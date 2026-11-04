import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';

import 'onboarding_test.dart' show pumpOnboarding;

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

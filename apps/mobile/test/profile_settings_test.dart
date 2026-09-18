import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/push.dart';

void main() {
  test('profile settings keep safe defaults for partial cloud payloads', () {
    final value = UserProfileSettings.fromJson({
      'displayName': 'Henry',
      'notifyGoals': false,
    });

    expect(value.displayName, 'Henry');
    expect(value.languageCode, 'es');
    expect(value.timezone, 'device');
    expect(value.hourFormat, 'system');
    expect(value.notifyKickoff, isTrue);
    expect(value.notifyGoals, isFalse);
    expect(value.notifyFinal, isTrue);
    expect(value.notifyCards, isTrue);
  });

  test('profile settings can clear the display name without losing toggles', () {
    const initial = UserProfileSettings(
      displayName: 'Henry',
      notifyCards: false,
      notifyTransfers: false,
    );

    final updated = initial.copyWith(
      clearDisplayName: true,
      notifyGoals: false,
    );

    expect(updated.displayName, isNull);
    expect(updated.notifyGoals, isFalse);
    expect(updated.notifyCards, isFalse);
    expect(updated.notifyTransfers, isFalse);
  });

  test('hour format accepts supported values and rejects unknown cloud data', () {
    final twentyFour = UserProfileSettings.fromJson({
      'hourFormat': '24h',
    });
    final invalid = UserProfileSettings.fromJson({
      'hourFormat': 'military-ish',
    });

    expect(twentyFour.hourFormat, '24h');
    expect(twentyFour.toJson()['hourFormat'], '24h');
    expect(invalid.hourFormat, 'system');
    expect(
      twentyFour.copyWith(hourFormat: '12h').hourFormat,
      '12h',
    );
  });
}

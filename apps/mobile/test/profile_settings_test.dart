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
}

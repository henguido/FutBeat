import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';

void main() {
  test(
    'FB-US-036/037/038: follows survive reopen and toggle independently',
    () async {
      final directory = await Directory.systemTemp.createTemp('futbeat-test-');
      final file = File('${directory.path}/follows.sqlite');
      var db = AppDatabase(NativeDatabase(file));
      try {
        await db.toggle('team', 'fb_team_sap');
        await db.toggle('player', 'fb_player_torres');
        await db.close();
        db = AppDatabase(NativeDatabase(file));
        expect(await db.watchFollows().first, {
          'team:fb_team_sap',
          'player:fb_player_torres',
        });
        await db.toggle('team', 'fb_team_sap');
        expect(await db.watchFollows().first, {'player:fb_player_torres'});
      } finally {
        await db.close();
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'country inference, manual selection and temporary interest stay separate',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        await db.savePreference(detectedCountry: 'CR', selectedCountry: null);
        var preference = await db.watchPreference().first;
        expect(preference.detectedCountry, 'CR');
        expect(preference.selectedCountry, isNull);
        expect(preference.effectiveCountry, 'CR');
        expect(await db.watchFollows().first, isEmpty);

        await db.savePreference(
          detectedCountry: 'CR',
          selectedCountry: 'MX',
          bootstrapDismissed: true,
        );
        preference = await db.watchPreference().first;
        expect(preference.detectedCountry, 'CR');
        expect(preference.selectedCountry, 'MX');
        expect(preference.effectiveCountry, 'MX');

        await db.touchInterest('match', 'fb_match_open');
        expect(await db.watchTemporaryInterests().first, {
          'match:fb_match_open',
        });
        expect(await db.watchFollows().first, isEmpty);
      } finally {
        await db.close();
      }
    },
  );
}

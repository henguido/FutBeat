import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';

void main() {
  test(
    'real v3 database upgrades to v4 without losing existing data',
    () async {
      final directory = await Directory.systemTemp.createTemp('futbeat-v3-');
      final file = File('${directory.path}/v3.sqlite');
      // These are the actual v3 tables, without any v4 ordering columns.
      var db = AppDatabase(
        NativeDatabase(
          file,
          setup: (sqlite) {
            sqlite.execute('''
        CREATE TABLE follows (entity_id TEXT NOT NULL, entity_type TEXT NOT NULL,
          PRIMARY KEY(entity_id, entity_type));
        CREATE TABLE preferences (id INTEGER NOT NULL DEFAULT 1 PRIMARY KEY,
          detected_country TEXT, selected_country TEXT,
          bootstrap_dismissed INTEGER NOT NULL DEFAULT 0
            CHECK(bootstrap_dismissed IN (0, 1)));
        CREATE TABLE temporary_interests (entity_id TEXT NOT NULL,
          entity_type TEXT NOT NULL, expires_at INTEGER NOT NULL,
          PRIMARY KEY(entity_id, entity_type));
        CREATE TABLE calendar_snapshots (calendar_date TEXT NOT NULL PRIMARY KEY,
          payload TEXT NOT NULL, saved_at INTEGER NOT NULL);
        INSERT INTO preferences VALUES (1, 'CR', 'JP', 1);
        INSERT INTO follows VALUES ('league-old', 'competition');
        INSERT INTO calendar_snapshots VALUES ('2026-09-20', '{}', 1700000000);
        PRAGMA user_version = 3;
      ''');
          },
        ),
      );
      try {
        final before = DateTime.now().subtract(const Duration(minutes: 1));
        final preference = await db.watchPreference().first;
        expect(preference.detectedCountry, 'CR');
        expect(preference.selectedCountry, 'JP');
        expect(preference.bootstrapDismissed, isTrue);
        expect(preference.competitionOrderMode, CompetitionOrderMode.automatic);
        expect(
          preference.competitionOrderPreference,
          CompetitionOrderPreference.countryFirst,
        );
        expect(preference.pinnedCompetitionIds, isEmpty);
        expect(preference.competitionOrderUpdatedAt, isNotNull);
        expect(preference.competitionOrderUpdatedAt!.isAfter(before), isTrue);
        expect(await db.watchFollows().first, {'competition:league-old'});
        expect(await db.readCalendarSnapshot('2026-09-20'), '{}');
        final columns = await db
            .customSelect('PRAGMA table_info(preferences)')
            .get();
        expect(
          columns.map((row) => row.read<String>('name')),
          containsAll([
            'competition_order_mode',
            'competition_order_preference',
            'pinned_competition_ids',
            'competition_order_updated_at',
          ]),
        );
        expect(
          (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
            'user_version',
          ),
          4,
        );
        await db.close();
        db = AppDatabase(NativeDatabase(file));
        final reopened = await db.watchPreference().first;
        expect(reopened.selectedCountry, 'JP');
        expect(
          reopened.competitionOrderUpdatedAt,
          preference.competitionOrderUpdatedAt,
        );
      } finally {
        await db.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'clean install has valid ordering defaults and persists timestamp',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final initial = await db.watchPreference().first;
        expect(initial.competitionOrderMode, CompetitionOrderMode.automatic);
        expect(
          initial.competitionOrderPreference,
          CompetitionOrderPreference.countryFirst,
        );
        expect(initial.pinnedCompetitionIds, isEmpty);
        await db.savePreference(detectedCountry: 'CR');
        expect(
          (await db.watchPreference().first).competitionOrderUpdatedAt,
          isNotNull,
        );
        expect(
          (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
            'user_version',
          ),
          4,
        );
      } finally {
        await db.close();
      }
    },
  );

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
    'calendar snapshots persist by civil date and replace stale rows',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        await db.saveCalendarSnapshot('2026-08-20', '{"version":1}');
        expect(await db.readCalendarSnapshot('2026-08-20'), '{"version":1}');
        await db.saveCalendarSnapshot('2026-08-20', '{"version":2}');
        expect(await db.readCalendarSnapshot('2026-08-20'), '{"version":2}');
        expect(await db.readCalendarSnapshot('2026-08-21'), isNull);
      } finally {
        await db.close();
      }
    },
  );
  test('personalized competition order survives a database reopen', () async {
    final directory = await Directory.systemTemp.createTemp('futbeat-order-');
    final file = File('${directory.path}/preferences.sqlite');
    var db = AppDatabase(NativeDatabase(file));
    try {
      await db.savePreference(
        competitionOrderMode: CompetitionOrderMode.personalized,
        competitionOrderPreference: CompetitionOrderPreference.globalFirst,
        pinnedCompetitionIds: const ['champions', 'laliga'],
      );
      await db.close();
      db = AppDatabase(NativeDatabase(file));
      final preference = await db.watchPreference().first;
      expect(
        preference.competitionOrderMode,
        CompetitionOrderMode.personalized,
      );
      expect(
        preference.competitionOrderPreference,
        CompetitionOrderPreference.globalFirst,
      );
      expect(preference.pinnedCompetitionIds, ['champions', 'laliga']);
      expect(preference.competitionOrderUpdatedAt, isNotNull);
    } finally {
      await db.close();
      await directory.delete(recursive: true);
    }
  });
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

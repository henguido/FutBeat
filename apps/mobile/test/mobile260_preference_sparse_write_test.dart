import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';

class _HoldPreferenceInsert extends QueryInterceptor {
  bool armed = false;
  bool holdAfterInsert = false;
  final entered = Completer<void>();
  final release = Completer<void>();
  final statements = <String>[];

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    statements.add(statement);
    if (armed && statement.toLowerCase().contains('preferences')) {
      armed = false;
      entered.complete();
      // The real SQLite statement has not started. Other real statements
      // can commit while this caller holds its already prepared stale write.
      await release.future;
    }
    final result = await executor.runInsert(statement, args);
    if (holdAfterInsert && statement.toLowerCase().contains('preferences')) {
      holdAfterInsert = false;
      entered.complete();
      await release.future;
    }
    return result;
  }
}

void main() {
  test(
    'the first visible row already includes explicit onboarding preferences',
    () async {
      final gate = _HoldPreferenceInsert()..holdAfterInsert = true;
      final db = AppDatabase(NativeDatabase.memory().interceptWith(gate));
      addTearDown(() async {
        if (!gate.release.isCompleted) gate.release.complete();
        await db.close();
      });
      final saved = db.savePreference(
        selectedCountry: 'MX',
        bootstrapDismissed: true,
        competitionOrderMode: 'manual',
        pinnedCompetitionIds: ['fb_comp_initial'],
      );
      await gate.entered.future.timeout(const Duration(seconds: 3));
      final first = await db.watchPreference().first;
      expect(first.selectedCountry, 'MX');
      expect(first.bootstrapDismissed, isTrue);
      expect(first.competitionOrderMode, 'manual');
      expect(first.pinnedCompetitionIds, ['fb_comp_initial']);
      gate.release.complete();
      await saved;
    },
  );
  test(
    'defaults, null sentinel and order timestamp survive a SQLite reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'futbeat-preferences260-',
      );
      final file = File('${directory.path}/preferences.sqlite');
      var db = AppDatabase(NativeDatabase(file));
      addTearDown(() async {
        await db.close();
        await directory.delete(recursive: true);
      });
      await db.savePreference();
      final defaults = await db.watchPreference().first;
      expect(defaults.bootstrapDismissed, isFalse);
      expect(defaults.competitionOrderMode, 'automatic');
      expect(defaults.competitionOrderPreference, 'country_first');
      expect(defaults.pinnedCompetitionIds, isEmpty);
      expect(defaults.competitionOrderUpdatedAt, isNotNull);
      final originalTime = defaults.competitionOrderUpdatedAt;
      await db.savePreference(detectedCountry: 'US', selectedCountry: 'MX');
      await db.savePreference(detectedCountry: null, selectedCountry: null);
      final cleared = await db.watchPreference().first;
      expect(cleared.detectedCountry, 'US');
      expect(cleared.selectedCountry, isNull);
      expect(cleared.competitionOrderUpdatedAt, originalTime);
      await db.savePreference(
        competitionOrderMode: 'manual',
        pinnedCompetitionIds: ['fb_comp_reopen', 'fb_comp_reopen'],
      );
      final orderTime =
          (await db.watchPreference().first).competitionOrderUpdatedAt;
      await db.close();
      db = AppDatabase(NativeDatabase(file));
      final reopened = await db.watchPreference().first;
      expect(reopened.selectedCountry, isNull);
      expect(reopened.detectedCountry, 'US');
      expect(reopened.competitionOrderMode, 'manual');
      expect(reopened.pinnedCompetitionIds, ['fb_comp_reopen']);
      expect(reopened.competitionOrderUpdatedAt, orderTime);
    },
  );
  test(
    'legacy null order timestamp is initialized without replacing country',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.saveSelectedCountry('MX');
      expect(
        (await db.watchPreference().first).competitionOrderUpdatedAt,
        isNull,
      );
      await db.savePreference();
      final saved = await db.watchPreference().first;
      expect(saved.selectedCountry, 'MX');
      expect(saved.competitionOrderUpdatedAt, isNotNull);
    },
  );
  for (final concurrent in ['country', 'clear', 'bootstrap']) {
    test(
      'sparse league order save preserves concurrent $concurrent mutation',
      () async {
        final gate = _HoldPreferenceInsert();
        final db = AppDatabase(NativeDatabase.memory().interceptWith(gate));
        addTearDown(() async {
          if (!gate.release.isCompleted) gate.release.complete();
          await db.close();
        });
        await db.savePreference(detectedCountry: 'US', selectedCountry: 'CR');
        gate.armed = true;
        final orderSave = db.savePreference(
          competitionOrderMode: 'manual',
          pinnedCompetitionIds: ['fb_comp_a', 'fb_comp_a'],
        );
        await gate.entered.future.timeout(const Duration(seconds: 3));
        if (concurrent == 'bootstrap') {
          await db.markBootstrapDismissed();
        } else {
          await db.saveSelectedCountry(concurrent == 'country' ? 'MX' : null);
        }
        gate.release.complete();
        await orderSave;
        final saved = await db.watchPreference().first;
        expect(
          saved.selectedCountry,
          concurrent == 'country'
              ? 'MX'
              : concurrent == 'clear'
              ? null
              : 'CR',
        );
        expect(saved.bootstrapDismissed, concurrent == 'bootstrap');
        expect(saved.detectedCountry, 'US');
        expect(saved.competitionOrderMode, 'manual');
        expect(saved.pinnedCompetitionIds, ['fb_comp_a']);
      },
    );
  }
}

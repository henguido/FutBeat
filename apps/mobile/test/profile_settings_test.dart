import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/push.dart';
import 'package:futbeat/features/profile/competition_order_preferences.dart';

void main() {
  for (final followed in [false, true]) {
    testWidgets(
      'ordering panel uses only followed names (followed=$followed)',
      (tester) async {
        var globalLoads = 0;
        final requestedKeys = <String>[];
        Snapshot snapshot() => Snapshot({
          'schemaVersion': 1,
          'demo': false,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'competitions': [
            {'id': 'fb_comp_cr', 'name': 'Liga Promerica'},
          ],
          'teams': <dynamic>[],
          'players': <dynamic>[],
          'matches': <dynamic>[],
          'standings': <dynamic>[],
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              preferenceProvider.overrideWith(
                (ref) => Stream.value(
                  const CountryPreference(
                    detectedCountry: 'CR',
                    selectedCountry: null,
                    bootstrapDismissed: true,
                    competitionOrderMode: CompetitionOrderMode.personalized,
                  ),
                ),
              ),
              followsProvider.overrideWith(
                (ref) => Stream.value({
                  'team:fb_team_ignored',
                  if (followed) 'competition:fb_comp_cr',
                }),
              ),
              snapshotProvider.overrideWith((ref) async {
                globalLoads++;
                return snapshot();
              }),
              favoritesSnapshotProvider.overrideWith((ref, keys) async {
                requestedKeys.add(keys);
                return snapshot();
              }),
            ],
            child: const MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(child: CompetitionOrderPanel()),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(globalLoads, 0);
        expect(find.text('Mi país primero'), findsNothing);
        expect(find.text('Grandes ligas primero'), findsNothing);
        expect(find.text('Tu país'), findsNothing);
        expect(requestedKeys, followed ? ['competition:fb_comp_cr'] : isEmpty);
        if (followed) expect(find.text('Liga Promerica'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

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

  test(
    'profile settings can clear the display name without losing toggles',
    () {
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
    },
  );

  test(
    'hour format accepts supported values and rejects unknown cloud data',
    () {
      final twentyFour = UserProfileSettings.fromJson({'hourFormat': '24h'});
      final invalid = UserProfileSettings.fromJson({
        'hourFormat': 'military-ish',
      });

      expect(twentyFour.hourFormat, '24h');
      expect(twentyFour.toJson()['hourFormat'], '24h');
      expect(invalid.hourFormat, 'system');
      expect(twentyFour.copyWith(hourFormat: '12h').hourFormat, '12h');
    },
  );
}

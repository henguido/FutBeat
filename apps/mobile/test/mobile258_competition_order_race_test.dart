import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/profile/competition_order_preferences.dart';

Future<AppDatabase> _panel(
  WidgetTester tester, {
  bool personalized = false,
}) async {
  final database = AppDatabase(NativeDatabase.memory());
  await tester.runAsync(
    () => database.savePreference(
      detectedCountry: 'CR',
      selectedCountry: 'CR',
      bootstrapDismissed: false,
      competitionOrderMode: personalized
          ? CompetitionOrderMode.personalized
          : CompetitionOrderMode.automatic,
      pinnedCompetitionIds: const ['fb_comp_a', 'fb_comp_b'],
    ),
  );
  final renderedPreference = await tester.runAsync(
    () => database.watchPreference().first,
  );
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(database),
      // Freeze the already-rendered frame while the real SQLite row changes.
      preferenceProvider.overrideWith(
        (ref) => Stream.value(renderedPreference!),
      ),
      followsProvider.overrideWith(
        (ref) => Stream.value(const {
          'competition:fb_comp_a',
          'competition:fb_comp_b',
        }),
      ),
      favoritesSnapshotProvider.overrideWith(
        (ref, keys) async => Snapshot({
          'schemaVersion': 1,
          'demo': false,
          'updatedAt': '2026-11-03T12:00:00Z',
          'competitions': [
            {'id': 'fb_comp_a', 'name': 'Competition A'},
            {'id': 'fb_comp_b', 'name': 'Competition B'},
          ],
          'teams': <dynamic>[],
          'players': <dynamic>[],
          'matches': <dynamic>[],
          'standings': <dynamic>[],
        }),
      ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump();
    await tester.runAsync(database.close);
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: CompetitionOrderPanel()),
        ),
      ),
    ),
  );
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    if (find.byType(SegmentedButton<String>).evaluate().isNotEmpty) break;
  }
  expect(find.byType(SegmentedButton<String>), findsOneWidget);
  await tester.pumpAndSettle();
  return database;
}

void main() {
  testWidgets(
    'changing order mode preserves preferences saved before repaint',
    (tester) async {
      final database = await _panel(tester);
      final mode = tester.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>),
      );
      // A stored change can complete between this frame and its next input.
      // The order control must not replay unrelated values from the old frame.
      await tester.runAsync(() async {
        await database.saveSelectedCountry('MX');
        await database.saveDetectedCountry('ES');
        await database.savePreference(
          bootstrapDismissed: true,
          competitionOrderPreference: CompetitionOrderPreference.globalFirst,
          pinnedCompetitionIds: const ['fb_comp_b'],
        );
      });
      final saved = await tester.runAsync(() async {
        mode.onSelectionChanged!({CompetitionOrderMode.personalized});
        return database
            .watchPreference()
            .firstWhere(
              (value) =>
                  value.competitionOrderMode ==
                  CompetitionOrderMode.personalized,
            )
            .timeout(const Duration(seconds: 5));
      });
      expect(saved!.selectedCountry, 'MX');
      expect(saved.detectedCountry, 'ES');
      expect(saved.bootstrapDismissed, isTrue);
      expect(saved.pinnedCompetitionIds, ['fb_comp_b']);
      expect(
        saved.competitionOrderPreference,
        CompetitionOrderPreference.globalFirst,
      );
    },
  );

  testWidgets('reordering only changes pins, not a newer mode or country', (
    tester,
  ) async {
    final database = await _panel(tester, personalized: true);
    final order = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    await tester.runAsync(
      () => database.savePreference(
        detectedCountry: 'ES',
        selectedCountry: 'MX',
        bootstrapDismissed: true,
        competitionOrderMode: CompetitionOrderMode.automatic,
        competitionOrderPreference: CompetitionOrderPreference.globalFirst,
      ),
    );
    final saved = await tester.runAsync(() async {
      order.onReorderItem!(0, 1);
      return database
          .watchPreference()
          .firstWhere(
            (value) => value.pinnedCompetitionIds.firstOrNull == 'fb_comp_b',
          )
          .timeout(const Duration(seconds: 5));
    });
    expect(saved!.pinnedCompetitionIds, ['fb_comp_b', 'fb_comp_a']);
    expect(saved.competitionOrderMode, CompetitionOrderMode.automatic);
    expect(saved.selectedCountry, 'MX');
    expect(saved.detectedCountry, 'ES');
    expect(saved.bootstrapDismissed, isTrue);
    expect(
      saved.competitionOrderPreference,
      CompetitionOrderPreference.globalFirst,
    );
  });
}

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/explore/explore_screen.dart';

void main() {
  testWidgets(
    'failed search waits for manual retry instead of spending budget on timers',
    (tester) async {
      final dio = Dio();
      var calls = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            calls++;
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
              ),
            );
          },
        ),
      );
      final container = ProviderContainer(
        overrides: [repositoryProvider.overrideWithValue(ApiRepository(dio))],
      );
      final provider = searchSnapshotProvider((
        query: 'arsenal',
        country: 'CR',
      ));
      final subscription = container.listen(provider, (_, _) {});
      for (
        var frame = 0;
        frame < 10 && !container.read(provider).hasError;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(container.read(provider).hasError, isTrue);
      await tester.pump(const Duration(minutes: 1));
      expect(calls, 1);
      expect(container.read(provider).hasError, isTrue);
      container.invalidate(provider);
      for (
        var frame = 0;
        frame < 10 && (calls < 2 || container.read(provider).isLoading);
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(container.read(provider).hasError, isTrue);
      expect(calls, 2);
      subscription.close();
      container.dispose();
      dio.close(force: true);
    },
  );

  testWidgets(
    'cached autocomplete deduplicates IDs, clears short input and cancels obsolete queries',
    (tester) async {
      final dio = Dio();
      final searches = <RequestOptions>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/v1/search') {
              searches.add(options);
              return;
            }
            handler.resolve(
              Response(
                requestOptions: options,
                data: {
                  'schemaVersion': 1,
                  'demo': false,
                  'updatedAt': '2026-11-06T00:00:00Z',
                  'teams': [
                    {'id': 'fb_team_arsenal', 'name': 'Arsenal'},
                    {'id': 'fb_team_arsenal', 'name': 'Arsenal'},
                    {'id': 'fb_team_arsenal_other', 'name': 'Arsenal'},
                    {'id': 'fb_team_everton', 'name': 'Everton'},
                  ],
                  for (final key in [
                    'players',
                    'competitions',
                    'matches',
                    'standings',
                  ])
                    key: <dynamic>[],
                },
              ),
            );
          },
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            repositoryProvider.overrideWithValue(ApiRepository(dio)),
            followsProvider.overrideWith((ref) => Stream.value(<String>{})),
            preferenceProvider.overrideWith(
              (ref) => Stream.value(
                const CountryPreference(
                  detectedCountry: 'CR',
                  selectedCountry: null,
                  bootstrapDismissed: true,
                ),
              ),
            ),
          ],
          child: const MaterialApp(home: ExploreScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final searchField = find.byType(TextField);
      final clear = find.byKey(const ValueKey('explore-clear-search'));
      expect(clear, findsNothing);
      await tester.enterText(searchField, 'a');
      await tester.pump(const Duration(milliseconds: 300));
      expect(clear, findsOneWidget);
      expect(searches, isEmpty);
      await tester.tap(clear);
      await tester.pump();
      expect(tester.widget<TextField>(searchField).controller!.text, isEmpty);
      expect(clear, findsNothing);
      await tester.enterText(find.byType(TextField), 'ars');
      await tester.pump();
      // Three source rows, but only two distinct teams; the homonym stays.
      expect(find.text('Arsenal'), findsNWidgets(2));
      expect(find.text('Everton'), findsNothing);
      expect(searches, isEmpty);
      await tester.pump(const Duration(milliseconds: 250));
      expect(searches, isEmpty);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 10));
      expect(searches, hasLength(1));
      await tester.enterText(find.byType(TextField), 'eve');
      await tester.pump();
      await tester.pump();
      expect(searches.single.cancelToken!.isCancelled, isTrue);
      expect(find.text('Arsenal'), findsNothing);
      expect(find.text('Everton'), findsOneWidget);
      expect(searches, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      dio.close(force: true);
    },
  );
}

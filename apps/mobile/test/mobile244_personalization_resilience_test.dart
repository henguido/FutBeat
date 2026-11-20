import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/push.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/profile/personalization_screen.dart';
import 'package:go_router/go_router.dart';

void main() {
  for (final error in [false, true]) {
    testWidgets(
      'local follow navigation survives hour settings ${error ? 'error' : 'loading'}',
      (tester) async {
        final pending = Completer<UserProfileSettings>();
        final router = GoRouter(
          initialLocation: '/profile/personalization',
          routes: [
            GoRoute(
              path: '/profile/personalization',
              builder: (_, _) => const PersonalizationScreen(),
            ),
            GoRoute(
              path: '/explore',
              builder: (_, state) => Scaffold(
                body: Text('explore:${state.uri.queryParameters['type']}'),
              ),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              preferenceProvider.overrideWith(
                (ref) => Stream.value(
                  const CountryPreference(
                    detectedCountry: 'CR',
                    selectedCountry: 'CR',
                    bootstrapDismissed: true,
                  ),
                ),
              ),
              followsProvider.overrideWith(
                (ref) => Stream.value(const <String>{}),
              ),
              profileSettingsProvider.overrideWith((ref) async {
                if (error) throw StateError('Synthetic settings unavailable');
                return pending.future;
              }),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pump();
        await tester.pump();
        final tile = find.byKey(const ValueKey('personalize-teams'));
        expect(tile, findsOneWidget);
        await tester.ensureVisible(tile);
        await tester.tap(tile);
        await tester.pumpAndSettle();
        expect(find.text('explore:team'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'hour settings error offers scoped retry without redoing personalization',
    (tester) async {
      var reads = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferenceProvider.overrideWith(
              (ref) => Stream.value(
                const CountryPreference(
                  detectedCountry: 'CR',
                  selectedCountry: 'CR',
                  bootstrapDismissed: true,
                ),
              ),
            ),
            followsProvider.overrideWith(
              (ref) => Stream.value(const <String>{}),
            ),
            profileSettingsProvider.overrideWith((ref) async {
              if (++reads == 1) {
                throw StateError('Synthetic settings unavailable');
              }
              return const UserProfileSettings();
            }),
          ],
          child: const MaterialApp(home: PersonalizationScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final retry = find.byKey(const ValueKey('retry-hour-format'));
      await tester.scrollUntilVisible(
        retry,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(retry, findsOneWidget);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(find.byKey(const ValueKey('hour-format')), findsOneWidget);
      expect(find.text('Personalizar FutBeat'), findsOneWidget);
    },
  );
}

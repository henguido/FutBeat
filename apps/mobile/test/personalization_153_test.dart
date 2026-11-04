import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/push.dart';
import 'package:futbeat/features/profile/personalization_screen.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets('Perfil personalization opens direct follow and alert flows', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
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
        GoRoute(
          path: '/profile/notifications',
          builder: (_, _) => const Scaffold(body: Text('alerts')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          preferenceProvider.overrideWith(
            (ref) => Stream.value(
              const CountryPreference(
                detectedCountry: 'CR',
                selectedCountry: 'CR',
                bootstrapDismissed: true,
              ),
            ),
          ),
          followsProvider.overrideWith((ref) => Stream.value(const <String>{})),
          profileSettingsProvider.overrideWith(
            (ref) async => const UserProfileSettings(),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    for (final (key, destination) in [
      ('personalize-teams', 'explore:team'),
      ('personalize-competitions', 'explore:competition'),
      ('personalize-players', 'explore:player'),
      ('personalize-alerts', 'alerts'),
    ]) {
      final tile = find.byKey(ValueKey(key));
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(find.text(destination), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });
}

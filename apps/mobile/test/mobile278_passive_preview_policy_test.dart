import 'package:futbeat/core/ads.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:futbeat/main.dart';

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/qa_development.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  testWidgets('passive navigation excludes News and maps every remaining tab', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/matches',
      routes: [
        ShellRoute(
          builder: (context, state, child) =>
              AppShell(location: state.uri.path, child: child),
          routes: [
            for (final path in AppShell.paths)
              GoRoute(path: path, builder: (_, _) => Text('screen $path')),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [adsEligibleProvider.overrideWithValue(false)],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Noticias'), findsNothing);
    expect(find.byType(NavigationDestination), findsNWidgets(4));
    for (final (label, path) in [
      ('Explorar', '/explore'),
      ('Favoritos', '/favorites'),
      ('Perfil', '/profile'),
    ]) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(find.text('screen $path'), findsOneWidget);
    }
  }, skip: !passivePreview);

  test(
    'disabled passive Preview blocks unrelated HTTP and live/auth config',
    () {
      final previous = HttpOverrides.current;
      addTearDown(() => HttpOverrides.global = previous);
      installPassivePreviewPolicy();
      expect(passivePreviewEnabled, isFalse);
      expect(HttpClient.new, throwsA(isA<SocketException>()));
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(liveRealtimeConfigProvider).isConfigured, isFalse);
    },
    skip: !passivePreview,
  );
}

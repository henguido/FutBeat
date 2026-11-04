import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/push.dart';
import 'package:futbeat/features/profile/about_screen.dart';
import 'package:futbeat/features/profile/profile_screen.dart';
import 'package:futbeat/features/profile/support_legal_screen.dart';
import 'package:futbeat/main.dart';
import 'package:go_router/go_router.dart';

Iterable<String> _paths(List<RouteBase> routes) sync* {
  for (final route in routes) {
    if (route is GoRoute) yield route.path;
    yield* _paths(route.routes);
  }
}

void main() {
  test('Profile V2 exposes every approved route', () {
    final router = createRouter(initialLocation: '/profile');
    addTearDown(router.dispose);
    final paths = _paths(router.configuration.routes).toSet();
    expect(
      paths,
      containsAll({
        '/profile/personalization',
        '/profile/notifications',
        '/profile/account',
        '/profile/premium',
        '/profile/privacy',
        '/profile/support',
        '/profile/about',
      }),
    );
  });

  test('notification summary is derived without changing preferences', () {
    const settings = UserProfileSettings(
      notifyKickoff: true,
      notifyGoals: true,
      notifyRedCards: true,
      notifyFinal: false,
      notifyNews: false,
      notifyTransfers: false,
    );
    final before = settings.toJson();
    expect(
      notificationSummary(settings),
      contains('Avísame al iniciar el partido'),
    );
    expect(settings.toJson(), before);
  });

  for (final width in [320.0, 360.0, 390.0]) {
    testWidgets('static Profile V2 sections fit ${width.toInt()}px', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final child in const [SupportLegalScreen(), AboutScreen()]) {
        await tester.pumpWidget(MaterialApp(home: child));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  }
}

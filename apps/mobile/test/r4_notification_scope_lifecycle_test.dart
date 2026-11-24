import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/notification_scopes.dart';
import 'package:futbeat/core/push.dart';
import 'package:futbeat/features/profile/notification_scopes_screen.dart';

import 'notification_scopes_test.dart' show matrix;

class NoTokens implements PushTokenSource {
  @override
  Future<String?> currentToken() async => null;
  @override
  Future<String?> requestToken() async => null;
  @override
  Stream<String> get rotations => const Stream.empty();
}

NotificationScopes choices(bool enabled) {
  final raw = matrix();
  for (final scope in (raw['scopes'] as Map).values) {
    for (final kind in (scope as Map).values) {
      kind['enabled'] = enabled;
    }
  }
  return NotificationScopes.fromJson(raw);
}

class ScopeService extends PushService {
  ScopeService(AppDatabase db)
    : super(
        const LiveRealtimeConfig(supabaseUrl: '', publicKey: ''),
        db,
        NoTokens(),
        pushConfigured: false,
      );
  final reads = <String?>[];
  final pendingReads = <String, Completer<NotificationScopes>>{};
  Completer<NotificationScopes>? pendingSave;
  bool failSave = false;
  void account(String id) => session = {
    'access_token': 'fixture',
    'user': {'id': id},
  };
  @override
  Future<NotificationScopes> readNotificationScopes() async {
    reads.add(userId);
    if (userId == null) throw StateError('Authentication required');
    return pendingReads[userId]?.future ?? choices(userId == 'A');
  }

  @override
  Future<NotificationScopes> setNotificationScope(
    String scope,
    String kind,
    bool? value,
  ) async {
    if (failSave) throw StateError('synthetic offline');
    return pendingSave?.future ?? choices(value ?? true);
  }
}

Future<ScopeService> open(
  WidgetTester tester, {
  bool holdInitial = false,
  bool withRouter = false,
}) async {
  final db = AppDatabase(NativeDatabase.memory());
  final service = ScopeService(db)..account('A');
  if (holdInitial) service.pendingReads['A'] = Completer<NotificationScopes>();
  final router = withRouter
      ? GoRouter(
          initialLocation: '/scopes',
          routes: [
            GoRoute(
              path: '/scopes',
              builder: (_, _) => const NotificationScopesScreen(),
            ),
            GoRoute(
              path: '/profile/account',
              builder: (_, _) => const Scaffold(body: Text('Acceso QA')),
            ),
          ],
        )
      : null;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    service.dispose();
    router?.dispose();
    await tester.runAsync(db.close);
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [pushServiceProvider.overrideWithValue(service)],
      child: router == null
          ? const MaterialApp(home: NotificationScopesScreen())
          : MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pump();
  return service;
}

Future<void> expand(WidgetTester tester) async {
  await tester.tap(find.text('Jugador'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'R4 lost session offers working sign-in instead of a failing retry',
    (tester) async {
      final service = await open(tester, withRouter: true);
      await tester.pumpAndSettle();
      service.session = null;
      await tester.pumpAndSettle();
      expect(find.text('Jugador'), findsNothing);
      expect(find.text('Reintentar'), findsNothing);
      await tester.tap(find.text('Iniciar sesión'));
      await tester.pumpAndSettle();
      expect(find.text('Acceso QA'), findsOneWidget);
    },
  );
  for (final failure in [false, true]) {
    testWidgets(
      'R4 late account A ${failure ? "error" : "answer"} cannot finish B load',
      (tester) async {
        final service = await open(tester, holdInitial: true);
        service.pendingReads['B'] = Completer<NotificationScopes>();
        service.account('B');
        await tester.pump();
        await tester.pump();
        expect(service.reads, ['A', 'B']);
        if (failure) {
          service.pendingReads['A']!.completeError(
            StateError('old account failure'),
          );
        } else {
          service.pendingReads['A']!.complete(choices(true));
        }
        await tester.pump();
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(find.textContaining('No pudimos'), findsNothing);
        service.pendingReads['B']!.complete(choices(false));
        await tester.pumpAndSettle();
        await expand(tester);
        expect(
          tester.widgetList<Switch>(find.byType(Switch)).every((s) => !s.value),
          isTrue,
        );
      },
    );
  }

  testWidgets(
    'R4 account switch hides prior preferences and ignores old save',
    (tester) async {
      final service = await open(tester);
      await tester.pumpAndSettle();
      await expand(tester);
      service.pendingSave = Completer<NotificationScopes>();
      await tester.tap(find.byType(Switch).first);
      await tester.pump();
      service.pendingReads['B'] = Completer<NotificationScopes>();
      service.account('B');
      await tester.pump();
      expect(find.byType(Switch), findsNothing);
      service.pendingSave!.complete(choices(true));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      service.pendingReads['B']!.complete(choices(false));
      await tester.pumpAndSettle();
      await expand(tester);
      expect(
        tester.widgetList<Switch>(find.byType(Switch)).every((s) => !s.value),
        isTrue,
      );
    },
  );

  testWidgets(
    'R4 retry preserves same-account confirmed choices while offline',
    (tester) async {
      final service = await open(tester);
      await tester.pumpAndSettle();
      await expand(tester);
      service.failSave = true;
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      service.pendingReads['A'] = Completer<NotificationScopes>();
      await tester.tap(find.text('Reintentar'));
      await tester.pump();
      expect(find.byType(Switch), findsWidgets);
      expect(
        tester.widgetList<Switch>(find.byType(Switch)).every((s) => s.value),
        isTrue,
      );
      service.pendingReads['A']!.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(find.byType(Switch), findsWidgets);
      expect(find.text('Reintentar'), findsOneWidget);
    },
  );
}

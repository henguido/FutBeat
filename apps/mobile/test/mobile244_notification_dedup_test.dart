import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/push_messages.dart';
import 'package:go_router/go_router.dart';

class _DryMessages implements PushMessageSource {
  @override
  Stream<PushMessage> get foreground => const Stream.empty();
  @override
  Stream<PushMessage> get opened => const Stream.empty();
  @override
  Future<PushMessage?> initial() async => null;
}

void main() {
  test(
    'server outbox identity survives FCM retries; never dedupe by content',
    () {
      expect(
        const PushMessage(
          deliveryId: 'transport-2',
          data: {'notificationId': 'outbox-1', 'eventId': 'goal-1'},
        ).deduplicationId,
        'outbox-1',
      );
      expect(
        const PushMessage(deliveryId: 'transport-1').deduplicationId,
        'transport-1',
      );
      expect(
        const PushMessage(
          title: 'Gol',
          data: {'matchId': 'fb_match_1'},
        ).deduplicationId,
        isNull,
      );
      expect(
        const PushMessage(data: {'notificationId': 'bad\nvalue'})
            .deduplicationId,
        isNull,
      );
    },
  );

  testWidgets(
    'retry cannot reopen a dismissed match; distinct correction can',
    (tester) async {
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: Text('Feed')),
          ),
          GoRoute(
            path: '/match/:id',
            builder: (_, _) => const Scaffold(body: Text('Match')),
          ),
        ],
      );
      final handler = PushMessageRouter(
        source: _DryMessages(),
        router: router,
        messenger: GlobalKey<ScaffoldMessengerState>(),
      );
      addTearDown(handler.dispose);
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      handler.open(
        const PushMessage(
          data: {'notificationId': 'goal-1', 'matchId': 'fb_match_1'},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Match'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      handler.open(
        const PushMessage(
          deliveryId: 'new-transport',
          data: {'notificationId': 'goal-1', 'matchId': 'fb_match_1'},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Feed'), findsOneWidget);
      handler.open(
        const PushMessage(
          data: {
            'notificationId': 'correction-1',
            'type': 'GOAL_ANNULLED',
            'matchId': 'fb_match_1',
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Match'), findsOneWidget);
    },
  );

  testWidgets(
    'foreground dedup still allows tap; every alert type opens canonical match',
    (tester) async {
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: Text('Feed')),
          ),
          GoRoute(
            path: '/match/:id',
            builder: (_, state) =>
                Scaffold(body: Text(state.pathParameters['id']!)),
          ),
        ],
      );
      final messenger = GlobalKey<ScaffoldMessengerState>();
      final handler = PushMessageRouter(
        source: _DryMessages(),
        router: router,
        messenger: messenger,
      );
      addTearDown(handler.dispose);
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          scaffoldMessengerKey: messenger,
        ),
      );
      for (final type in [
        'GOAL',
        'KICKOFF',
        'FINAL',
        'RED_CARD',
        'PLAYER_STARTER',
        'PLAYER_BENCH',
        'GOAL_ANNULLED',
      ]) {
        final message = PushMessage(
          title: type,
          data: {
            'notificationId': 'synthetic-$type',
            'type': type,
            'matchId': 'fb_match_synthetic244',
          },
        );
        handler.showBanner(message);
        await tester.pumpAndSettle();
        messenger.currentState!.removeCurrentSnackBar();
        await tester.pumpAndSettle();
        handler.showBanner(message);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('push-banner')), findsNothing);
        handler.open(message);
        await tester.pumpAndSettle();
        expect(find.text('fb_match_synthetic244'), findsOneWidget);
        router.pop();
        await tester.pumpAndSettle();
      }
    },
  );
}

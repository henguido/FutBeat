import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/push_messages.dart';
import 'package:go_router/go_router.dart';

const _match = 'fb_match_notification245';

class _LocalMessages implements PushMessageSource {
  final taps = StreamController<PushMessage>.broadcast();
  final launched = Completer<PushMessage?>();
  @override
  Stream<PushMessage> get foreground => const Stream.empty();
  @override
  Stream<PushMessage> get opened => taps.stream;
  @override
  Future<PushMessage?> initial() => launched.future;
  Future<void> close() async {
    if (!launched.isCompleted) launched.complete(null);
    await taps.close();
  }
}

PushMessage _message(String id) => PushMessage(
  title: 'Gol sintético',
  body: 'Mismo texto; la identidad es la del outbox, no este texto.',
  data: {'notificationId': id, 'matchId': _match, 'type': 'GOAL'},
);

GoRouter _router() => GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (_, _) => const Scaffold(body: Text('Feed local')),
    ),
    GoRoute(
      path: '/match/:id',
      builder: (_, state) => Scaffold(body: Text(state.pathParameters['id']!)),
    ),
  ],
);

void main() {
  test(
    'malformed outbox identity uses only a valid bounded transport identity',
    () {
      for (final invalid in <Object?>[
        null,
        17,
        {'untrusted': 'object'},
        '',
        '   ',
        'invalid\nidentity',
        List.filled(201, 'a').join(),
      ]) {
        final message = PushMessage(
          deliveryId: 'transport-local-245',
          data: {'notificationId': invalid, 'matchId': _match},
        );
        expect(message.deduplicationId, 'transport-local-245');
        expect(message.route, '/match/$_match');
      }
      expect(
        PushMessage(
          deliveryId: List.filled(201, 'b').join(),
        data: const {'notificationId': 'bad\nidentity', 'matchId': _match},
        ).deduplicationId,
        isNull,
      );
    },
  );

  testWidgets(
    'bounded dedup keeps recent deliveries and evicts the oldest only',
    (tester) async {
      final source = _LocalMessages();
      final router = _router();
      final handler = PushMessageRouter(
        source: source,
        router: router,
        messenger: GlobalKey<ScaffoldMessengerState>(),
      );
      addTearDown(() async {
        handler.dispose();
        router.dispose();
        await source.close();
      });
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      handler.open(_message('outbox-0'));
      await tester.pumpAndSettle();
      expect(find.text(_match), findsOneWidget);
      // The same screen is already visible: remembering deliveries must not
      // push another route. 129 identities exceed the explicit 128-entry bound.
      for (var i = 1; i <= 128; i++) {
        handler.open(_message('outbox-$i'));
      }
      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('Feed local'), findsOneWidget);
      handler.open(_message('outbox-128'));
      await tester.pumpAndSettle();
      expect(find.text('Feed local'), findsOneWidget);
      handler.open(_message('outbox-0'));
      await tester.pumpAndSettle();
      expect(find.text(_match), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('Feed local'), findsOneWidget); // No hidden route stack.
    },
  );

  testWidgets(
    'late initial delivery cannot reopen a dismissed background tap',
    (tester) async {
      final source = _LocalMessages();
      final router = _router();
      final handler = PushMessageRouter(
        source: source,
        router: router,
        messenger: GlobalKey<ScaffoldMessengerState>(),
      );
      addTearDown(() async {
        handler.dispose();
        router.dispose();
        await source.close();
      });
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      handler.start();
      source.taps.add(_message('outbox-shared'));
      await tester.pumpAndSettle();
      expect(find.text(_match), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      source.launched.complete(_message('outbox-shared'));
      await tester.pumpAndSettle();
      expect(find.text('Feed local'), findsOneWidget);
      // Same text/match with a new outbox identity remains a separate event.
      source.taps.add(_message('outbox-next-goal'));
      await tester.pumpAndSettle();
      expect(find.text(_match), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

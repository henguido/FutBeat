import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/live_realtime.dart';

import 'live_bootstrap_test.dart' show FakeSupabase, liveRow;

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Local LIVE fixture milestone');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  for (final scoped in [true, false]) {
    test(
      'disposing LIVE closes an active stream and socket (scoped=$scoped)',
      () async {
        const id = 'fb_match_dispose258';
        final server = FakeSupabase([
          liveRow(id, updatedAt: DateTime.now().toUtc()),
        ]);
        await server.start();
        final dio = Dio();
        final client = LiveRealtimeClient(
          LiveRealtimeConfig(
            supabaseUrl: server.url,
            publicKey: 'local-fixture',
          ),
          dio,
          scopedRealtime: scoped,
          refreshInterval: const Duration(hours: 1),
        )..setScope('match:open', [id]);
        final done = Completer<void>();
        final subscription = client.watch().listen(
          (_) {},
          onDone: done.complete,
        );
        try {
          await until(
            () => server.joins.isNotEmpty && server.restRequests.length >= 2,
          );
          final closed = server.sockets.single.done;
          client.dispose();
          await done.future.timeout(const Duration(seconds: 2));
          await closed.timeout(const Duration(seconds: 2));
          final requests = server.restRequests.length;
          await client.refreshOnResume();
          expect(server.restRequests.length, requests);
        } finally {
          await subscription.cancel();
          client.dispose();
          dio.close(force: true);
          await server.stop();
        }
      },
    );
  }

  test(
    'disposing LIVE cancels an in-flight REST bootstrap without waiting for it',
    () async {
      const id = 'fb_match_held258';
      final release = Completer<void>();
      final cancelled = Completer<void>();
      final server = FakeSupabase([
        liveRow(id, updatedAt: DateTime.now().toUtc()),
      ], realtime: false);
      server.beforeAnswerAsync = (_) => release.future;
      await server.start();
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onError: (error, handler) {
            if (CancelToken.isCancel(error) && !cancelled.isCompleted)
              cancelled.complete();
            handler.next(error);
          },
        ),
      );
      final client = LiveRealtimeClient(
        LiveRealtimeConfig(supabaseUrl: server.url, publicKey: 'local-fixture'),
        dio,
        scopedRealtime: true,
        refreshInterval: const Duration(hours: 1),
      )..setScope('match:open', [id]);
      final subscription = client.watch().listen((_) {});
      try {
        await until(() => server.restRequests.isNotEmpty);
        client.dispose();
        await cancelled.future.timeout(const Duration(seconds: 2));
      } finally {
        release.complete();
        await subscription.cancel();
        client.dispose();
        dio.close(force: true);
        await server.stop();
      }
    },
  );

  test('a disposed LIVE client cannot start a fresh watch', () async {
    final server = FakeSupabase([]);
    await server.start();
    final dio = Dio();
    final client = LiveRealtimeClient(
      LiveRealtimeConfig(supabaseUrl: server.url, publicKey: 'local-fixture'),
      dio,
      refreshInterval: const Duration(hours: 1),
    );
    client.dispose();
    final done = Completer<void>();
    final subscription = client.watch().listen((_) {}, onDone: done.complete);
    try {
      await done.future.timeout(const Duration(seconds: 2));
      expect(server.restRequests, isEmpty);
      expect(server.sockets, isEmpty);
    } finally {
      await subscription.cancel();
      dio.close(force: true);
      await server.stop();
    }
  });

  test(
    'disposing LIVE closes every active watch owned by that client',
    () async {
      const id = 'fb_match_multiple258';
      final server = FakeSupabase([
        liveRow(id, updatedAt: DateTime.now().toUtc()),
      ]);
      await server.start();
      final dio = Dio();
      final client = LiveRealtimeClient(
        LiveRealtimeConfig(supabaseUrl: server.url, publicKey: 'local-fixture'),
        dio,
        scopedRealtime: true,
        refreshInterval: const Duration(hours: 1),
      )..setScope('match:open', [id]);
      final done = [Completer<void>(), Completer<void>()];
      final subscriptions = [
        for (final signal in done)
          client.watch().listen((_) {}, onDone: signal.complete),
      ];
      try {
        await until(() => server.joins.length == 2);
        client.dispose();
        await Future.wait(done.map((signal) => signal.future))
            .timeout(const Duration(seconds: 2));
        await Future.wait(server.sockets.map((socket) => socket.done))
            .timeout(const Duration(seconds: 2));
      } finally {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        client.dispose();
        dio.close(force: true);
        await server.stop();
      }
    },
  );

  test(
    'a paused listener cannot keep LIVE network resources open after dispose',
    () async {
      const id = 'fb_match_paused258';
      final server = FakeSupabase([
        liveRow(id, updatedAt: DateTime.now().toUtc()),
      ]);
      await server.start();
      final dio = Dio();
      final client = LiveRealtimeClient(
        LiveRealtimeConfig(supabaseUrl: server.url, publicKey: 'local-fixture'),
        dio,
        scopedRealtime: true,
        refreshInterval: const Duration(hours: 1),
      )..setScope('match:open', [id]);
      final done = Completer<void>();
      final subscription = client.watch().listen((_) {}, onDone: done.complete);
      try {
        await until(
          () => server.joins.isNotEmpty && server.restRequests.length >= 2,
        );
        subscription.pause();
        client.dispose();
        await server.sockets.single.done.timeout(const Duration(seconds: 2));
        subscription.resume();
        await done.future.timeout(const Duration(seconds: 2));
      } finally {
        await subscription.cancel();
        client.dispose();
        dio.close(force: true);
        await server.stop();
      }
    },
  );
}

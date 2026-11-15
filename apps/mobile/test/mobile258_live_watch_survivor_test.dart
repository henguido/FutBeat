import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/live_realtime.dart';

import 'live_bootstrap_test.dart' show FakeSupabase, liveRow;

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Local LIVE survivor fixture milestone');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  for (final cancelledIndex in [0, 1]) {
    for (final action in ['background', 'refresh']) {
      test(
        'LIVE survivor handles $action after watch $cancelledIndex is cancelled',
        () async {
          const id = 'fb_match_survivor258';
          final server = FakeSupabase([
            liveRow(id, updatedAt: DateTime.now().toUtc()),
          ]);
          await server.start();
          var completedReads = 0;
          final dio = Dio();
          dio.interceptors.add(
            InterceptorsWrapper(
              onResponse: (response, handler) {
                if (response.requestOptions.uri.path.endsWith(
                  '/live_match_updates',
                )) {
                  completedReads++;
                }
                handler.next(response);
              },
            ),
          );
          final client = LiveRealtimeClient(
            LiveRealtimeConfig(
              supabaseUrl: server.url,
              publicKey: 'local-fixture',
            ),
            dio,
            scopedRealtime: true,
            refreshInterval: const Duration(hours: 1),
          )..setScope('match:open', [id]);
          final subscriptions = [
            client.watch().listen((_) {}),
            client.watch().listen((_) {}),
          ];
          try {
            await _until(
              () =>
                  server.joins.length == 2 &&
                  completedReads >= 4 &&
                  completedReads == server.restRequests.length,
            );
            // Server request arrival is not client bootstrap completion.
            // Drain the response continuations before testing a new refresh.
            await Future<void>.delayed(Duration.zero);
            await subscriptions[cancelledIndex].cancel();
            await _until(
              () =>
                  server.sockets
                      .where((socket) => socket.readyState == WebSocket.open)
                      .length ==
                  1,
            );
            if (action == 'background') {
              // Connection order need not equal watch order. Identify the
              // still-open transport after the cancelled watch is closed.
              final survivor = server.sockets.singleWhere(
                (socket) => socket.readyState == WebSocket.open,
              );
              client.setAppActive(false);
              await survivor.done.timeout(const Duration(seconds: 1));
            } else {
              final reads = server.restRequests.length;
              await client.refreshOnResume();
              expect(
                server.restRequests.length,
                reads + 1,
                reason: 'the remaining watch still owns its refresh callback',
              );
            }
          } finally {
            client.dispose();
            for (final subscription in subscriptions) {
              await subscription.cancel();
            }
            dio.close(force: true);
            await server.stop();
          }
        },
      );
    }
  }
}

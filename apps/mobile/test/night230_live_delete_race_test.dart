import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/models.dart';

import 'live_bootstrap_test.dart' show FakeSupabase, liveRow;

Future<void> _until(bool Function() condition) async {
  final limit = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(limit)) throw TimeoutException('LIVE condition');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  for (final reinsert in [false, true]) {
    test('a late bootstrap cannot undo realtime DELETE'
        '${reinsert ? ' followed by a new corrected INSERT' : ''}', () async {
      final now = DateTime.now().toUtc();
      const id = 'fb_match_delete_race';
      final row = liveRow(id, updatedAt: now, home: 1);
      final server = FakeSupabase([row]);
      await server.start();
      addTearDown(server.stop);
      final dio = Dio();
      addTearDown(() => dio.close(force: true));
      final client = LiveRealtimeClient(
        LiveRealtimeConfig(supabaseUrl: server.url, publicKey: 'local-test'),
        dio,
        scopedRealtime: true,
        refreshInterval: const Duration(hours: 1),
      );
      client.setScope('match:open', [id]);
      var latest = <String, LiveMatchUpdate>{};
      var emissions = 0;
      final subscription = client.watch().listen((value) {
        latest = value;
        emissions++;
      });
      addTearDown(() async {
        await subscription.cancel();
        client.dispose();
      });
      await _until(
        () =>
            latest[id]?.homeScore == 1 &&
            server.restRequests.length >= 2 &&
            emissions >= 2,
      );
      // Both initial and subscribe-gap reads have emitted their result.
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      server.beforeAnswerAsync = (_) async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      final refresh = client.refreshOnResume();
      await entered.future.timeout(const Duration(seconds: 5));
      void frame(String type, Json value) => server.sockets.last.add(
        jsonEncode({
          'event': 'postgres_changes',
          'payload': {
            'data': {
              'type': type,
              type == 'DELETE' ? 'old_record' : 'record': value,
            },
          },
        }),
      );
      frame('DELETE', {'match_id': id});
      await _until(() => !latest.containsKey(id));
      if (reinsert) {
        frame('INSERT', liveRow(id, updatedAt: now, revision: 2, home: 0));
        await _until(() => latest[id]?.revision == 2);
      }
      // The in-flight REST answer still contains revision 1, score 1–0.
      release.complete();
      await refresh;
      await Future<void>.delayed(Duration.zero);
      if (reinsert) {
        expect(latest[id]?.revision, 2);
        expect(latest[id]?.homeScore, 0);
      } else {
        expect(latest, isNot(contains(id)));
      }
      expect(server.restRequests, hasLength(3));
    });
  }
}

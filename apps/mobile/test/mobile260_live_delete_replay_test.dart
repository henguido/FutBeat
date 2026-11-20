import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/models.dart';

import 'live_bootstrap_test.dart' show FakeSupabase, liveRow;

Future<void> until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('LIVE fixture');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('an older replay cannot resurrect a deleted LIVE version', () async {
    const id = 'fb_match_stale_delete259';
    final now = DateTime.now().toUtc();
    final older = liveRow(id, updatedAt: now, revision: 1, home: 1);
    final newer = liveRow(id, updatedAt: now, revision: 2, home: 0);
    final server = FakeSupabase([newer]);
    await server.start();
    final dio = Dio();
    final client = LiveRealtimeClient(
      LiveRealtimeConfig(supabaseUrl: server.url, publicKey: 'local-fixture'),
      dio,
      scopedRealtime: true,
      refreshInterval: const Duration(hours: 1),
    )..setScope('match:open', [id]);
    var latest = <String, LiveMatchUpdate>{};
    var emissions = 0;
    final subscription = client.watch().listen((value) {
      latest = value;
      emissions++;
    });
    try {
      await until(() => latest[id]?.revision == 2 && emissions >= 2);
      void delete(Map<String, dynamic> row) => server.sockets.last.add(
        jsonEncode({
          'event': 'postgres_changes',
          'payload': {
            'data': {'type': 'DELETE', 'old_record': row},
          },
        }),
      );
      delete(newer);
      await until(() => !latest.containsKey(id));
      final afterDelete = emissions;
      server.sockets.last.add(
        jsonEncode({
          'event': 'postgres_changes',
          'payload': {
            'data': {'type': 'UPDATE', 'record': older},
          },
        }),
      );
      await until(() => emissions > afterDelete);
      expect(latest, isNot(contains(id)));
      // An even older DELETE must not weaken the version fence.
      final afterReplay = emissions;
      delete(older);
      await until(() => emissions > afterReplay);
      final afterOlderDelete = emissions;
      server.sockets.last.add(
        jsonEncode({
          'event': 'postgres_changes',
          'payload': {
            'data': {'type': 'UPDATE', 'record': newer},
          },
        }),
      );
      await until(() => emissions > afterOlderDelete);
      expect(latest, isNot(contains(id)));
      // A subsequent REST read can contain an older replica row too.
      server.rows[id] = older;
      await client.refreshOnResume();
      expect(latest, isNot(contains(id)));
      // A newer incarnation may reset its provider revision.
      final reinserted = liveRow(
        id,
        updatedAt: now.add(const Duration(seconds: 1)),
        revision: 1,
        home: 3,
      );
      server.sockets.last.add(
        jsonEncode({
          'event': 'postgres_changes',
          'payload': {
            'data': {'type': 'INSERT', 'record': reinserted},
          },
        }),
      );
      await until(() => latest[id]?.homeScore == 3);
      delete(reinserted);
      await until(() => !latest.containsKey(id));
      // Revision spaces are independent when ownership changes provider.
      server.sockets.last.add(
        jsonEncode({
          'event': 'postgres_changes',
          'payload': {
            'data': {
              'type': 'INSERT',
              'record': {
                ...reinserted,
                'provider': 'other-provider',
                'home_score': 4,
              },
            },
          },
        }),
      );
      await until(() => latest[id]?.homeScore == 4);
    } finally {
      client.dispose();
      await subscription.cancel();
      dio.close(force: true);
      await server.stop();
    }
  });
}

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
  test('older full DELETE cannot erase a newer correction', () async {
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
      final before = emissions;
      void delete(Map<String, dynamic> row) => server.sockets.last.add(
        jsonEncode({
          'event': 'postgres_changes',
          'payload': {
            'data': {'type': 'DELETE', 'old_record': row},
          },
        }),
      );
      delete(older);
      await until(() => emissions > before);
      expect(latest[id]?.revision, 2);
      expect(latest[id]?.homeScore, 0);
      final afterRevision = emissions;
      delete({
        ...older,
        'provider': 'another-provider',
        'revision': 99,
        'changed_at': now
            .subtract(const Duration(seconds: 1))
            .toIso8601String(),
      });
      await until(() => emissions > afterRevision);
      expect(latest[id]?.revision, 2);
      expect(latest[id]?.homeScore, 0);
      // A deletion of the current revision still removes the overlay.
      delete(newer);
      await until(() => !latest.containsKey(id));
    } finally {
      client.dispose();
      await subscription.cancel();
      dio.close(force: true);
      await server.stop();
    }
  });
}

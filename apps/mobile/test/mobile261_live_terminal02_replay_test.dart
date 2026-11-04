import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/models.dart';

import 'live_bootstrap_test.dart' show FakeSupabase, liveRow;
import 'mobile260_live_delete_replay_test.dart' show until;

void main() {
  for (final transport in ['realtime', 'rest', 'resume']) {
    test(
      'terminal version does not revive from $transport replay after complete absence on resume',
      () async {
        const id = 'fb_match_terminal02';
        final now = DateTime.now().toUtc();
        final old = liveRow(
          id,
          updatedAt: now.subtract(const Duration(seconds: 1)),
          revision: 1,
          home: 0,
        );
        final finalRow = liveRow(
          id,
          status: 'VERIFIED',
          updatedAt: now,
          revision: 2,
          home: 1,
        );
        final server = FakeSupabase([old]);
        await server.start();
        final dio = Dio();
        final client = LiveRealtimeClient(
          LiveRealtimeConfig(
            supabaseUrl: server.url,
            publicKey: 'local-fixture',
          ),
          dio,
          scopedRealtime: true,
          refreshInterval: const Duration(hours: 1),
        )..setScope('match:open', [id]);
        var latest = <String, LiveMatchUpdate>{};
        var count = 0;
        final sub = client.watch().listen((value) {
          latest = value;
          count++;
        });
        void send(Map<String, dynamic> row) => server.sockets.last.add(
          jsonEncode({
            'event': 'postgres_changes',
            'payload': {
              'data': {'type': 'UPDATE', 'record': row},
            },
          }),
        );
        try {
          await until(
            () =>
                latest[id]?.revision == 1 &&
                server.joins.isNotEmpty &&
                count >= 2,
          );
          send(finalRow);
          await until(() => latest[id]?.status == 'VERIFIED');
          // The overlay row can leave the hot table once its terminal snapshot is stored.
          server.rows.clear();
          final beforeAbsent = count;
          await client.refreshOnResume();
          await until(() => count > beforeAbsent);
          expect(
            latest,
            isNot(contains(id)),
            reason:
                'Complete absence remains authoritative for overlay removal',
          );
          if (transport == 'realtime') {
            final before = count;
            send(old);
            await until(() => count > before);
          } else {
            if (transport == 'resume') client.setAppActive(false);
            server.rows[id] = old;
            final beforeReplay = count;
            if (transport == 'resume') client.setAppActive(true);
            await client.refreshOnResume();
            await until(() => count > beforeReplay);
          }
          expect(
            latest,
            isNot(contains(id)),
            reason: 'Removing a terminal overlay must not forget its ordering evidence and admit the older LIVE replay',
          );
          // A genuinely newer terminal correction remains admissible.
          final corrected = liveRow(
            id,
            status: 'VERIFIED',
            updatedAt: now.add(const Duration(seconds: 1)),
            revision: 3,
            home: 2,
          );
          send(corrected);
          await until(() => latest[id]?.revision == 3);
          expect(latest[id]!.homeScore, 2);
          expect(latest[id]!.status, 'VERIFIED');
        } finally {
          client.dispose();
          await sub.cancel();
          dio.close(force: true);
          await server.stop();
        }
      },
    );
  }
  test('retired terminal fences share the configured page bound and clear on watch close', () async {
    final now = DateTime.now().toUtc();
    final ids = [for (var i = 0; i < 2; i++) 'fb_terminal_bound_$i'];
    final server = FakeSupabase([
      for (final id in ids)
        liveRow(id, status: 'VERIFIED', updatedAt: now, revision: 2),
    ]);
    await server.start();
    final dio = Dio();
    final client = LiveRealtimeClient(
      LiveRealtimeConfig(supabaseUrl: server.url, publicKey: 'fixture'),
      dio,
      scopedRealtime: false,
      bootstrapPolicy: const LiveBootstrapPolicy(pageSize: 2, maxPages: 1),
      refreshInterval: const Duration(hours: 1),
    )..setScope('match:open', ids);
    var latest = <String, LiveMatchUpdate>{};
    var count = 0;
    var sub = client.watch().listen((value) {
      latest = value;
      count++;
    });
    try {
      await until(
        () =>
            latest.length == ids.length &&
            count >= 2 &&
            server.joins.isNotEmpty,
      );
      server.rows.clear();
      await client.refreshOnResume();
      await until(() => latest.isEmpty);
      expect(latest, isEmpty);
      const extra = 'fb_terminal_bound_extra';
      server.rows[extra] = liveRow(
        extra,
        status: 'VERIFIED',
        updatedAt: now,
        revision: 2,
      );
      await client.refreshOnResume();
      await until(() => latest.containsKey(extra));
      server.rows.clear();
      await client.refreshOnResume();
      await until(() => latest.isEmpty);
      expect(latest, isEmpty);
      // Three retired versions cannot be retained in a two-row bootstrap budget.
      // The oldest fence is evicted; the next one still rejects its replay.
      server.rows[ids.first] = liveRow(
        ids.first,
        updatedAt: now.subtract(const Duration(seconds: 1)),
        revision: 1,
      );
      server.rows[ids[1]] = liveRow(
        ids[1],
        updatedAt: now.subtract(const Duration(seconds: 1)),
        revision: 1,
      );
      await client.refreshOnResume();
      await until(() => latest.containsKey(ids.first));
      expect(latest[ids.first]?.revision, 1);
      expect(latest, isNot(contains(ids[1])));
      await sub.cancel();
      latest = {};
      count = 0;
      sub = client.watch().listen((value) {
        latest = value;
        count++;
      });
      await until(() => latest.containsKey(ids[1]));
      expect(
        latest[ids[1]]!.revision,
        1,
        reason: 'Closed watches must not leak their version history into a new watch',
      );
    } finally {
      client.dispose();
      await sub.cancel();
      dio.close(force: true);
      await server.stop();
    }
  });
}

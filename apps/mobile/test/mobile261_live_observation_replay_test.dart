import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/models.dart';

import 'live_bootstrap_test.dart' show FakeSupabase, liveRow;
import 'mobile260_live_delete_replay_test.dart' show until;

void main() {
  final now = DateTime.utc(2026, 11, 3, 12);
  Map<String, dynamic> row(DateTime observed, {int revision = 3}) => {
    ...liveRow(
      'fb_match261',
      revision: revision,
      updatedAt: now,
      changedAt: now.subtract(const Duration(hours: 1)),
    ),
    'provider_observed_at': observed.toIso8601String(),
  };
  test(
    'REST replay of identical content retains newer provider observation',
    () {
      final current = LiveMatchUpdate.fromJson(row(now), receivedAt: now);
      final merged = reconcileLiveBootstrapSnapshot(
        {'fb_match261': current},
        [row(now.subtract(const Duration(minutes: 20)))],
        serverNow: now,
        deviceNow: now,
      );
      expect(merged['fb_match261']!.observedAt, now);
      expect(merged['fb_match261'], same(current));
    },
  );
  test('new provider observation of unchanged content is accepted', () {
    final current = LiveMatchUpdate.fromJson(
      row(now.subtract(const Duration(minutes: 20))),
      receivedAt: now.subtract(const Duration(minutes: 20)),
    );
    final merged = reconcileLiveBootstrapSnapshot(
      {'fb_match261': current},
      [row(now)],
      serverNow: now,
      deviceNow: now,
    );
    expect(merged['fb_match261']!.observedAt, now);
  });
  test('new revision remains authoritative even with older observation', () {
    final current = LiveMatchUpdate.fromJson(row(now), receivedAt: now);
    final merged = reconcileLiveBootstrapSnapshot(
      {'fb_match261': current},
      [row(now.subtract(const Duration(minutes: 1)), revision: 4)],
      serverNow: now,
      deviceNow: now,
    );
    expect(merged['fb_match261']!.revision, 4);
  });
  test(
    'Realtime old observation cannot make an unchanged live score stale',
    () async {
      final now = DateTime.now().toUtc();
      const id = 'fb_match261_ws';
      final recent = <String, dynamic>{
        ...liveRow(id, updatedAt: now),
        'provider_observed_at': now.toIso8601String(),
      };
      final old = <String, dynamic>{
        ...recent,
        'provider_observed_at': now
            .subtract(const Duration(minutes: 20))
            .toIso8601String(),
      };
      final server = FakeSupabase([recent]);
      await server.start();
      final dio = Dio();
      final client = LiveRealtimeClient(
        LiveRealtimeConfig(supabaseUrl: server.url, publicKey: 'fixture'),
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
      try {
        await until(
          () =>
              latest.containsKey(id) &&
              server.sockets.isNotEmpty &&
              server.joins.isNotEmpty,
        );
        final before = count;
        server.sockets.last.add(
          jsonEncode({
            'event': 'postgres_changes',
            'payload': {
              'data': {'type': 'UPDATE', 'record': old},
            },
          }),
        );
        await until(() => count > before);
        expect(latest[id]!.observedAt, now);
        expect(
          DateTime.now().toUtc().difference(latest[id]!.receivedAt!),
          lessThan(const Duration(minutes: 15)),
        );
      } finally {
        await sub.cancel();
        client.dispose();
        dio.close(force: true);
        await server.stop();
      }
    },
  );
}

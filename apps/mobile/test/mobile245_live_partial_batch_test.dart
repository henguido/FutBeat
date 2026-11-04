import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/models.dart';

// Synthetic local contract rows; no real fixture/provider observation.
final _now = DateTime.utc(2026, 11, 1, 12);
Json _row(String id, {int revision = 1, int score = 1}) => {
  'match_id': id,
  'provider': 'goal_api',
  'external_match_id': 'synthetic-$id',
  'status': 'LIVE',
  'minute': 30,
  'home_score': score,
  'away_score': 0,
  'revision': revision,
  'event_count': 0,
  'latest_events': <Json>[],
  'changed_at': _now.toIso8601String(),
};

LiveMatchUpdate _overlay(String id) =>
    LiveMatchUpdate.fromJson(_row(id), receivedAt: _now);

void main() {
  test(
    'malformed content preserves its known canonical overlay, not all rows',
    () {
      const kept = 'fb_match_kept245';
      const absent = 'fb_match_absent245';
      final previous = _overlay(kept);
      final bad = _row(kept)..['revision'] = 'not-a-number';
      final result = reconcileLiveBootstrapSnapshot(
        {kept: previous, absent: _overlay(absent)},
        [bad],
        serverNow: _now,
        deviceNow: _now,
      );
      expect(identical(result[kept], previous), isTrue);
      expect(result[kept]!.homeScore, 1);
      // A readable identity still lets an otherwise complete answer remove a
      // different, genuinely absent row. This is not a permanent deletion ban.
      expect(result, isNot(contains(absent)));
    },
  );

  test('unidentified malformed row cannot prove any overlay was deleted', () {
    const id = 'fb_match_unknown245';
    final previous = _overlay(id);
    final result = reconcileLiveBootstrapSnapshot(
      {id: previous},
      [
        <String, dynamic>{'status': 'LIVE'},
      ],
      serverNow: _now,
      deviceNow: _now,
    );
    expect(identical(result[id], previous), isTrue);
    // A later valid complete snapshot can still establish absence.
    expect(reconcileLiveBootstrapSnapshot(result, const []), isEmpty);
  });

  test('bad peer row does not suppress a valid goal correction', () {
    const id = 'fb_match_corrected245';
    const badId = 'fb_match_bad245';
    final previous = _overlay(id);
    final correction = _row(id, revision: 2, score: 0);
    final result = reconcileLiveBootstrapSnapshot(
      {id: previous, badId: _overlay(badId)},
      [correction, _row(badId)..['changed_at'] = 'invalid-date'],
      serverNow: _now,
      deviceNow: _now,
    );
    expect(result[id]!.revision, 2);
    expect(result[id]!.homeScore, 0);
    expect(result[badId]!.revision, 1);
    expect(result[badId]!.homeScore, 1);
    // An old revision cannot resurrect the corrected goal on another read.
    expect(
      reconcileLiveBootstrapSnapshot(result, [
        _row(id),
      ], complete: false)[id]!.homeScore,
      0,
    );
  });

  test('non-object REST list entry makes a short page partial', () async {
    const id = 'fb_match_page245';
    final dio = Dio();
    addTearDown(() => dio.close(force: true));
    var requests = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          requests++;
          handler.resolve(
            Response(
              requestOptions: request,
              headers: Headers.fromMap({
                'date': [HttpDate.format(_now)],
              }),
              data: [_row(id, revision: 2, score: 0), null],
            ),
          );
        },
      ),
    );
    final read = await fetchLiveBootstrap(
      dio,
      const LiveRealtimeConfig(
        supabaseUrl: 'https://127.0.0.1:9',
        publicKey: 'synthetic-test-only',
      ),
      const LiveBootstrapPolicy(pageSize: 10),
      since: _now.subtract(const Duration(hours: 1)),
    );
    expect(requests, 1);
    expect(read.complete, isFalse);
    expect(read.exhausted, isFalse);
    expect(read.rows.single['match_id'], id);
    const absent = 'fb_match_not_proven_absent245';
    final result = reconcileLiveBootstrapSnapshot(
      {id: _overlay(id), absent: _overlay(absent)},
      read.rows,
      complete: read.complete,
      deviceNow: _now,
      serverNow: read.serverNow,
    );
    expect(result[id]!.homeScore, 0);
    expect(result, contains(absent));
  });
}

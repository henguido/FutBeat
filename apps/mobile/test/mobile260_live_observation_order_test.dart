import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';

void main() {
  final changed = DateTime.utc(2026, 11, 3, 11);
  LiveMatchUpdate update(
    DateTime observation, {
    int revision = 3,
    DateTime? receipt,
  }) => LiveMatchUpdate(
    matchId: 'fb_match260',
    provider: 'goal_api',
    externalMatchId: '260',
    status: 'LIVE',
    minute: 65,
    homeScore: 1,
    awayScore: 0,
    revision: revision,
    eventCount: 0,
    changedAt: changed,
    observedAt: observation,
    receivedAt: receipt ?? observation,
  );
  final raw = <String, dynamic>{
    'id': 'fb_match260',
    'status': 'SCHEDULED',
    'events': [],
  };
  test('snapshot overlay preserves newer freshness after a serialized cache round trip', () {
    final recent = DateTime.utc(2026, 11, 3, 12);
    final stored = jsonDecode(
      jsonEncode(
        update(recent).applyTo({
          ...raw,
          'competitionId': 'fb_comp260',
          'homeTeamId': 'fb_home260',
          'awayTeamId': 'fb_away260',
          'startTime': '2026-11-03T10:00:00Z',
        }),
      ),
    );
    final snapshot = Snapshot({
      'schemaVersion': 1,
      'demo': false,
      'updatedAt': recent.toIso8601String(),
      'teams': [
        {'id': 'fb_home260', 'name': 'Local'},
        {'id': 'fb_away260', 'name': 'Visita'},
      ],
      'competitions': [
        {'id': 'fb_comp260', 'name': 'Liga'},
      ],
      'players': [],
      'standings': [],
      'matches': [stored],
    });
    final result = snapshot.withLiveUpdates({
      'fb_match260': update(recent.subtract(const Duration(minutes: 30))),
    });
    expect(
      result.match('fb_match260')!.json['liveObservedAt'],
      recent.toIso8601String(),
    );
  });
  test('equal observation keeps its later device receipt but a new revision still applies', () {
    final recent = DateTime.utc(2026, 11, 3, 12);
    final stored = update(changed, receipt: recent).applyTo(raw);
    final delayed = update(changed, receipt: changed).applyTo(stored);
    expect(
      delayed['liveObservationDeviceAt'],
      stored['liveObservationDeviceAt'],
    );
    final correction = update(
      changed,
      revision: 4,
      receipt: changed,
    ).applyTo(stored);
    expect(correction['liveRevision'], 4);
  });
  test('same content revision cannot regress its provider observation and device freshness', () {
    final recent = DateTime.utc(2026, 11, 3, 12);
    final stored = update(recent).applyTo(raw);
    final lateOld = update(recent.subtract(const Duration(minutes: 30)))
        .applyTo(stored);
    expect(lateOld['liveObservedAt'], stored['liveObservedAt']);
    expect(
      lateOld['liveObservationDeviceAt'],
      stored['liveObservationDeviceAt'],
    );
    expect(FootballMatch(lateOld).liveDataStaleAt(recent), isFalse);
  });
  test(
    'a newer observation of unchanged content still refreshes freshness',
    () {
      final recent = DateTime.utc(2026, 11, 3, 12);
      final stored = update(recent.subtract(const Duration(minutes: 30)))
          .applyTo(raw);
      final fresh = update(recent).applyTo(stored);
      expect(fresh['liveObservedAt'], recent.toIso8601String());
      expect(FootballMatch(fresh).liveDataStaleAt(recent), isFalse);
    },
  );
}

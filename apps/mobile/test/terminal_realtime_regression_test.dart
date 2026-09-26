import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';

// #120: a terminal canonical snapshot is absorbing. Realtime is an overlay
// and can never downgrade it, whatever its changedAt.

const _id = 'fb_match_terminal_guard';
const _home = 'fb_team_home_terminal_guard';
const _away = 'fb_team_away_terminal_guard';
final _kickoff = DateTime.utc(2026, 9, 20, 18);

Json _match({
  required String status,
  Map<String, int>? score,
  int? minute,
  String? liveChangedAt,
  int? liveRevision,
  String? liveProvider,
  List<Json> events = const [],
}) => {
  'id': _id,
  'competitionId': 'fb_comp_terminal_guard',
  'homeTeamId': _home,
  'awayTeamId': _away,
  'startTime': _kickoff.toIso8601String(),
  'status': status,
  'score': score,
  'minute': minute,
  'events': events,
  'statistics': <dynamic>[],
  'liveChangedAt': ?liveChangedAt,
  'liveRevision': ?liveRevision,
  'liveProvider': ?liveProvider,
  'provenance': {
    'source': 'GOAL API',
    // Canonical evidence OLDER than the realtime rows below: the previous
    // guard let any later realtime row overwrite the final.
    'receivedAt': _kickoff.add(const Duration(hours: 2)).toIso8601String(),
  },
};

LiveMatchUpdate _update({
  required String status,
  int? minute,
  int? home,
  int? away,
  int revision = 5,
  String provider = 'goal_api',
  DateTime? changedAt,
  List<Json> events = const [],
}) => LiveMatchUpdate(
  matchId: _id,
  provider: provider,
  externalMatchId: 'ext-terminal-guard',
  status: status,
  minute: minute,
  homeScore: home,
  awayScore: away,
  revision: revision,
  eventCount: events.length,
  changedAt: changedAt ?? _kickoff.add(const Duration(hours: 3)),
  events: events,
);

void main() {
  test(
    'A. canonical VERIFIED 3-4 + later realtime LIVE 3-3 => stays VERIFIED 3-4',
    () {
      final canonical = _match(
        status: 'VERIFIED',
        score: {'home': 3, 'away': 4},
        minute: 90,
      );
      final merged = _update(
        status: 'LIVE',
        minute: 67,
        home: 3,
        away: 3,
      ).applyTo(canonical);
      expect(identical(merged, canonical), isTrue);
      final match = FootballMatch(merged);
      expect(match.status, 'VERIFIED');
      expect(match.score, '3 - 4');
      expect(match.json['minute'], 90);
      expect(match.isLive, isFalse);
    },
  );

  test('B. canonical FINISHED_PENDING_VERIFICATION 2-2 + later HALFTIME 1-1 => unchanged', () {
    final canonical = _match(
      status: 'FINISHED_PENDING_VERIFICATION',
      score: {'home': 2, 'away': 2},
    );
    final merged = _update(
      status: 'HALFTIME',
      minute: 45,
      home: 1,
      away: 1,
    ).applyTo(canonical);
    expect(FootballMatch(merged).status, 'FINISHED_PENDING_VERIFICATION');
    expect(FootballMatch(merged).score, '2 - 2');
  });

  test('C. realtime hours later is still ignored; no realtime-only events appended', () {
    final canonical = _match(status: 'VERIFIED', score: {'home': 1, 'away': 4});
    final merged = _update(
      status: 'HALFTIME',
      minute: 45,
      home: 1,
      away: 1,
      revision: 99,
      changedAt: _kickoff.add(const Duration(hours: 30)),
      events: [
        {
          'id': 'fb_event_rt_only',
          'matchId': _id,
          'teamId': _home,
          'type': 'GOAL',
          'minute': 12,
        },
      ],
    ).applyTo(canonical);
    expect(identical(merged, canonical), isTrue);
    expect(FootballMatch(merged).events, isEmpty);
    expect(merged.containsKey('liveRevision'), isFalse);
  });

  test('every terminal canonical status is absorbing', () {
    for (final status in [
      'FINISHED_PENDING_VERIFICATION',
      'VERIFIED',
      'POSTPONED',
      'ABANDONED',
      'CANCELLED',
    ]) {
      final canonical = _match(
        status: status,
        score: status == 'POSTPONED' ? null : {'home': 0, 'away': 1},
      );
      for (final incoming in ['LIVE', 'HALFTIME', 'SCHEDULED', 'VERIFIED']) {
        final merged = _update(
          status: incoming,
          minute: 30,
          home: 5,
          away: 5,
        ).applyTo(canonical);
        expect(
          identical(merged, canonical),
          isTrue,
          reason: '$status <- $incoming',
        );
      }
    }
  });

  test('D. canonical scheduled + valid LIVE update => becomes LIVE', () {
    final merged = _update(status: 'LIVE', minute: 12, home: 1, away: 0)
        .applyTo(
          _match(status: 'SCHEDULED'),
          now: _kickoff.add(const Duration(hours: 3)),
        );
    final match = FootballMatch(merged);
    expect(match.status, 'LIVE');
    expect(match.score, '1 - 0');
    expect(match.statusLabel, '12′ · En vivo');
  });

  test('E. canonical LIVE + newer LIVE update => applies normally', () {
    final canonical = _match(
      status: 'LIVE',
      score: {'home': 1, 'away': 0},
      minute: 40,
      liveChangedAt: _kickoff
          .add(const Duration(minutes: 40))
          .toIso8601String(),
      liveRevision: 3,
      liveProvider: 'goal_api',
    );
    final merged = _update(
      status: 'LIVE',
      minute: 55,
      home: 2,
      away: 0,
      revision: 4,
      changedAt: _kickoff.add(const Duration(minutes: 70)),
    ).applyTo(canonical, now: _kickoff.add(const Duration(minutes: 71)));
    expect(FootballMatch(merged).score, '2 - 0');
    expect(merged['minute'], 55);
    expect(merged['liveRevision'], 4);
  });

  test('F. older realtime update or lower revision => existing ordering guard still wins', () {
    final canonical = _match(
      status: 'LIVE',
      score: {'home': 2, 'away': 0},
      minute: 60,
      liveChangedAt: _kickoff
          .add(const Duration(minutes: 70))
          .toIso8601String(),
      liveRevision: 6,
      liveProvider: 'goal_api',
    );
    final older = _update(
      status: 'LIVE',
      minute: 30,
      home: 1,
      away: 0,
      revision: 7,
      changedAt: _kickoff.add(const Duration(minutes: 35)),
    );
    expect(identical(older.applyTo(canonical), canonical), isTrue);
    final lowerRevision = _update(
      status: 'LIVE',
      minute: 61,
      home: 1,
      away: 0,
      revision: 5,
      changedAt: _kickoff.add(const Duration(minutes: 75)),
    );
    expect(identical(lowerRevision.applyTo(canonical), canonical), isTrue);
  });

  test('G/H. Match Center label from a terminal canonical stays Finalizado, never Marcador parcial', () {
    final raw = jsonDecode(
      File('assets/demo.snapshot.json').readAsStringSync(),
    ) as Json;
    final matches = (raw['matches'] as List).cast<Json>().toList();
    final first = Json.of(matches.first)
      ..['status'] = 'VERIFIED'
      ..['score'] = {'home': 1, 'away': 4}
      ..['startTime'] = DateTime.now()
          .toUtc()
          .subtract(const Duration(hours: 5))
          .toIso8601String()
      ..['provenance'] = {
        'source': 'GOAL API',
        'receivedAt': DateTime.now()
            .toUtc()
            .subtract(const Duration(hours: 3))
            .toIso8601String(),
      };
    matches[0] = first;
    final snapshot = Snapshot({...raw, 'demo': false, 'matches': matches});
    final id = first['id'] as String;

    for (final (status, minute) in [
      ('LIVE', 67),
      ('HALFTIME', 45),
      ('SCHEDULED', null),
      ('PRE_MATCH', null),
    ]) {
      final merged = snapshot.withLiveUpdates({
        id: LiveMatchUpdate(
          matchId: id,
          provider: 'goal_api',
          externalMatchId: 'ext-demo',
          status: status,
          minute: minute,
          homeScore: 1,
          awayScore: 1,
          revision: 50,
          eventCount: 0,
          changedAt: DateTime.now().toUtc(),
        ),
      });
      expect(identical(merged, snapshot), isTrue, reason: status);
      final match = merged.match(id)!;
      expect(match.statusLabel, 'Finalizado', reason: status);
      expect(match.statusLabel, isNot('Marcador parcial'));
      expect(match.score, '1 - 4');
      expect(match.isLive, isFalse);
    }
  });

  test(
    '#120 client: a silent LIVE overlay (>15 min) never keeps a match live',
    () {
      final canonical = _match(status: 'SCHEDULED');
      final changedAt = _kickoff.add(const Duration(minutes: 80));
      final update = _update(
        status: 'LIVE',
        minute: 90,
        home: 2,
        away: 3,
        changedAt: changedAt,
      );
      final fresh = update.applyTo(
        canonical,
        now: changedAt.add(const Duration(minutes: 5)),
      );
      expect(fresh['status'], 'LIVE');
      final silent = update.applyTo(
        canonical,
        now: changedAt.add(const Duration(minutes: 16)),
      );
      expect(identical(silent, canonical), isTrue);
      expect(FootballMatch(silent).isLive, isFalse);
    },
  );

  test('#120 client: a terminal overlay applies however old it is', () {
    final changedAt = _kickoff.add(const Duration(minutes: 110));
    final merged =
        _update(
          status: 'FINISHED_PENDING_VERIFICATION',
          minute: 90,
          home: 2,
          away: 3,
          changedAt: changedAt,
        ).applyTo(
          _match(status: 'LIVE'),
          now: changedAt.add(const Duration(hours: 5)),
        );
    expect(merged['status'], 'FINISHED_PENDING_VERIFICATION');
    expect(FootballMatch(merged).score, '2 - 3');
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';

// The latest authoritative state REPLACES the previous one: an annulled
// goal, a corrected score, and a corrected final result. Generic fixtures.

final Json _demo =
    jsonDecode(File('assets/demo.snapshot.json').readAsStringSync()) as Json;
// A real match of the demo snapshot (its teams and competition exist there).
final Json _base = (_demo['matches'] as List).first as Json;
final String _id = _base['id'] as String;
final String _home = _base['homeTeamId'] as String;
final String _away = _base['awayTeamId'] as String;

Json _goal(String id, int minute, String team) => {
  'id': id,
  'matchId': _id,
  'type': 'GOAL',
  'minute': minute,
  'teamId': team,
  'provider': 'goal_api',
};

Json _match({
  required String status,
  Map<String, int>? score,
  List<Json> events = const [],
}) => {
  ..._base,
  'startTime': DateTime.now()
      .toUtc()
      .subtract(const Duration(hours: 1))
      .toIso8601String(),
  'status': status,
  'score': score,
  'events': events,
  'statistics': <dynamic>[],
  'provenance': {
    'source': 'GOAL API',
    'receivedAt': DateTime.now().toUtc().toIso8601String(),
  },
};

var _revision = 0;
LiveMatchUpdate _live(
  int home,
  int away, {
  String status = 'LIVE',
  List<Json> events = const [],
}) {
  final now = DateTime.now().toUtc().add(Duration(seconds: ++_revision));
  return LiveMatchUpdate.fromJson({
    'match_id': _id,
    'provider': 'goal_api',
    'external_match_id': 'ext-score-fix',
    'status': status,
    'minute': 20 + _revision,
    'home_score': home,
    'away_score': away,
    'revision': _revision,
    'event_count': events.length,
    'latest_events': events,
    'changed_at': now.toIso8601String(),
  });
}

Snapshot _snapshot(Json match) => Snapshot({
  ..._demo,
  'demo': false,
  'matches': [match],
});

void main() {
  test('annulled goal: 1-0 then 0-0 => FutBeat shows 0-0 and no goal', () {
    final goal = _goal('fb_event_g1', 19, _home);
    var match = _match(status: 'SCHEDULED');
    // A) first state 1-0 with its goal.
    match = _live(1, 0, events: [goal]).applyTo(match);
    expect(FootballMatch(match).score, '1 - 0');
    expect(FootballMatch(match).events, hasLength(1));
    // B) the provider annuls it: 0-0, no goal listed.
    match = _live(0, 0).applyTo(match);
    // C) final FutBeat state.
    final shown = FootballMatch(match);
    expect(shown.score, '0 - 0');
    expect(shown.events.where((e) => e['type'] == 'GOAL'), isEmpty);
    expect(shown.isLive, isTrue);
  });

  test('corrected score: 1-1 -> 2-1 -> 1-1 => FutBeat shows 1-1', () {
    final g1 = _goal('fb_event_a', 10, _home);
    final g2 = _goal('fb_event_b', 30, _away);
    final g3 = _goal('fb_event_c', 70, _home);
    var match = _match(status: 'SCHEDULED');
    match = _live(1, 1, events: [g1, g2]).applyTo(match);
    match = _live(2, 1, events: [g1, g2, g3]).applyTo(match);
    expect(FootballMatch(match).score, '2 - 1');
    match = _live(1, 1, events: [g1, g2]).applyTo(match);
    final shown = FootballMatch(match);
    expect(shown.score, '1 - 1');
    expect(shown.events.map((e) => e['id']), ['fb_event_a', 'fb_event_b']);
    // Through the feed snapshot as well.
    final viaSnapshot =
        _snapshot(
          _match(
            status: 'LIVE',
            score: {'home': 2, 'away': 1},
            events: [g1, g2, g3],
          ),
        ).withLiveUpdates({
          _id: _live(1, 1, events: [g1, g2]),
        });
    expect(viaSnapshot.match(_id)!.score, '1 - 1');
  });

  test('an out-of-order older update never restores the annulled goal', () {
    final goal = _goal('fb_event_g1', 19, _home);
    final first = _live(1, 0, events: [goal]);
    final second = _live(0, 0);
    var match = second.applyTo(first.applyTo(_match(status: 'SCHEDULED')));
    match = first.applyTo(match); // late redelivery of the older row
    expect(FootballMatch(match).score, '0 - 0');
  });

  test('corrected FINAL: a new canonical snapshot replaces the stored final; '
      'a stale realtime row cannot bring the old one back', () {
    // The app holds a final 2-1.
    final before = _snapshot(
      _match(
        status: 'FINISHED_PENDING_VERIFICATION',
        score: {'home': 2, 'away': 1},
      ),
    );
    expect(before.match(_id)!.score, '2 - 1');
    // The backend corrects the canonical final to 1-1: the next snapshot is
    // the truth, whatever realtime row the client still has.
    final staleRealtime = {
      _id: _live(2, 1, status: 'FINISHED_PENDING_VERIFICATION'),
    };
    final after = _snapshot(
      _match(
        status: 'FINISHED_PENDING_VERIFICATION',
        score: {'home': 1, 'away': 1},
      ),
    ).withLiveUpdates(staleRealtime);
    final shown = after.match(_id)!;
    expect(shown.score, '1 - 1');
    expect(shown.statusLabel, 'Finalizado');
  });
}

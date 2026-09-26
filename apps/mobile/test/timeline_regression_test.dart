import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/matches/match_screen.dart';

// #121: Match Center timeline order and identity-aware merging. Generic
// fixtures only (no real teams, fixtures or players).

const _home = 'fb_team_tl_home';
const _away = 'fb_team_tl_away';

FootballMatch _match(List<Json> events) => FootballMatch({
  'id': 'fb_match_tl',
  'competitionId': 'fb_comp_tl',
  'homeTeamId': _home,
  'awayTeamId': _away,
  'startTime': DateTime.utc(2026, 9, 20, 18).toIso8601String(),
  'status': 'VERIFIED',
  'score': {'home': 2, 'away': 1},
  'events': events,
  'statistics': <dynamic>[],
});

MatchDetail _detail(List<Json> incidents) => MatchDetail({
  ...MatchDetail.empty('fb_match_tl').json,
  'available': true,
  'incidents': incidents,
});

Json _ev(
  String id,
  String type, {
  int? minute,
  int? extra,
  String? team,
  String? player,
  String? key,
  bool synthetic = false,
  Map<String, int>? score,
  String? detail,
}) => {
  'id': id,
  'type': type,
  'minute': minute,
  'extraMinute': ?extra,
  'teamId': ?team,
  'playerId': ?player,
  if (key != null) ...{'providerEventKey': key, 'provider': 'goal_api'},
  if (synthetic) 'synthetic': true,
  'score': ?score,
  'detail': ?detail,
};

List<String> _ids(List<Json> timeline) =>
    timeline.map((e) => e['id'] as String).toList();

void main() {
  test(
    'phases: KICKOFF first, HALFTIME after 45+x, FULL_TIME (minute null) last',
    () {
      final match = _match([
        _ev('ft', 'FULL_TIME'),
        _ev('g60', 'GOAL', minute: 60, team: _home, player: 'p1'),
        _ev('ht', 'HALFTIME', minute: 45),
        _ev(
          'c45',
          'YELLOW_CARD',
          minute: 45,
          extra: 2,
          team: _away,
          player: 'p2',
        ),
        _ev('g46', 'GOAL', minute: 46, team: _away, player: 'p3'),
        _ev('ko', 'KICKOFF', minute: 0),
        _ev('g10', 'GOAL', minute: 10, team: _home, player: 'p4'),
        _ev(
          's909',
          'SUBSTITUTION',
          minute: 90,
          extra: 9,
          team: _home,
          player: 'p5',
        ),
        _ev('g905', 'GOAL', minute: 90, extra: 5, team: _home, player: 'p6'),
      ]);
      final expected = [
        'ko',
        'g10',
        'c45',
        'ht',
        'g46',
        'g60',
        'g905',
        's909',
        'ft',
      ];
      expect(_ids(match.events), expected);
      expect(_ids(mergedMatchTimeline(match, _detail(const []))), expected);
    },
  );

  test('compareTimelineEvents: 90+5 before 90+9; null FULL_TIME never before kickoff', () {
    Json e(String type, int? minute, [int? extra]) => {
      'id': '$type$minute$extra',
      'type': type,
      'minute': minute,
      'extraMinute': extra,
    };
    expect(
      compareTimelineEvents(e('GOAL', 90, 5), e('GOAL', 90, 9)),
      lessThan(0),
    );
    expect(
      compareTimelineEvents(e('FULL_TIME', null), e('KICKOFF', 0)),
      greaterThan(0),
    );
    expect(
      compareTimelineEvents(e('FULL_TIME', null), e('GOAL', 120, 3)),
      greaterThan(0),
    );
    expect(
      compareTimelineEvents(e('HALFTIME', 45), e('GOAL', 45, 4)),
      greaterThan(0),
    );
    expect(
      compareTimelineEvents(e('HALFTIME', 45), e('GOAL', 46)),
      lessThan(0),
    );
  });

  test('canonical 90 + detail 90+5 with the same provider event id => one event (detail wins)', () {
    final match = _match([
      _ev('live90', 'GOAL', minute: 90, team: _home, player: 'p1', key: '9500'),
    ]);
    final timeline = mergedMatchTimeline(
      match,
      _detail([
        {
          'type': 'GOAL',
          'minute': 90,
          'extraMinute': 5,
          'side': 'home',
          'detail': 'Anotador',
          'providerEventId': '9500',
        },
      ]),
    );
    final goals = timeline.where((e) => e['type'] == 'GOAL').toList();
    expect(goals, hasLength(1));
    expect(eventMinuteLabel(goals.single), '90+5′');
    expect(goals.single['detailSource'], isTrue);
  });

  test(
    'synthetic 25 + rich goal 23 same team => rich wins, no technical copy',
    () {
      final match = _match([
        _ev(
          'syn',
          'GOAL',
          minute: 25,
          team: _home,
          synthetic: true,
          score: {'home': 1, 'away': 0},
          detail: 'Marcador actualizado',
        ),
        _ev('rich', 'GOAL', minute: 23, team: _home, player: 'p1'),
      ]);
      final timeline = mergedMatchTimeline(match, _detail(const []));
      expect(_ids(timeline), ['rich']);
      // Also against a detail row as the rich evidence.
      final withDetail = mergedMatchTimeline(
        _match([match.events.first]),
        _detail([
          {'type': 'GOAL', 'minute': 23, 'side': 'home', 'detail': 'Anotador'},
        ]),
      );
      expect(withDetail.where((e) => e['type'] == 'GOAL'), hasLength(1));
      expect(withDetail.single['detailSource'], isTrue);
    },
  );

  test('two real goals at 20 and 23 (same team) and a later synthetic for goal 2 stay two', () {
    final match = _match([
      _ev('g20', 'GOAL', minute: 20, team: _home, player: 'p1'),
      _ev('g23', 'GOAL', minute: 23, team: _home, player: 'p1', key: '2'),
      _ev(
        'syn2',
        'GOAL',
        minute: 23,
        team: _home,
        synthetic: true,
        score: {'home': 2, 'away': 0},
      ),
    ]);
    expect(_ids(mergedMatchTimeline(match, _detail(const []))), ['g20', 'g23']);
    // Without the rich goal 2, the synthetic stays as the second goal.
    final partial = _match([
      _ev('g20', 'GOAL', minute: 20, team: _home, player: 'p1'),
      _ev(
        'syn2',
        'GOAL',
        minute: 23,
        team: _home,
        synthetic: true,
        score: {'home': 2, 'away': 0},
      ),
    ]);
    expect(_ids(mergedMatchTimeline(partial, _detail(const []))), [
      'g20',
      'syn2',
    ]);
  });

  test('different players / cards close together are preserved', () {
    final match = _match([
      _ev('c1', 'YELLOW_CARD', minute: 55, team: _away, player: 'p1'),
      _ev('c2', 'YELLOW_CARD', minute: 55, team: _away, player: 'p2'),
      _ev('g1', 'GOAL', minute: 20, team: _home, player: 'p3'),
      _ev('g2', 'GOAL', minute: 20, team: _home, player: 'p4'),
    ]);
    expect(mergedMatchTimeline(match, _detail(const [])), hasLength(4));
    // Two detail cards at the same minute replace their two canonical twins one-to-one.
    final withDetail = mergedMatchTimeline(
      match,
      _detail([
        {'type': 'YELLOW_CARD', 'minute': 55, 'side': 'away', 'detail': 'Uno'},
        {'type': 'YELLOW_CARD', 'minute': 55, 'side': 'away', 'detail': 'Dos'},
      ]),
    );
    expect(withDetail.where((e) => e['type'] == 'YELLOW_CARD'), hasLength(2));
    expect(withDetail.where((e) => e['detailSource'] == true), hasLength(2));
  });

  test('"Marcador actualizado" is never user copy; synthetic-only goal renders as a goal', () {
    final match = _match([
      _ev(
        'syn',
        'GOAL',
        minute: 33,
        team: _away,
        synthetic: true,
        score: {'home': 0, 'away': 1},
        detail: 'Marcador actualizado',
      ),
    ]);
    final timeline = mergedMatchTimeline(match, _detail(const []));
    expect(timeline.single['type'], 'GOAL');
    expect(timeline.single.containsKey('detail'), isFalse);
    expect(match.events.single.containsKey('detail'), isFalse);
    expect(timeline.toString(), isNot(contains('Marcador actualizado')));
  });

  test('player/team side alignment is kept for the surviving event', () {
    final match = _match([
      _ev('home', 'GOAL', minute: 12, team: _home, player: 'p1'),
      _ev('away', 'GOAL', minute: 12, team: _away, player: 'p2'),
    ]);
    final timeline = mergedMatchTimeline(
      match,
      _detail([
        {'type': 'GOAL', 'minute': 12, 'side': 'away', 'detail': 'Visitante'},
      ]),
    );
    expect(timeline, hasLength(2));
    expect(timeline.firstWhere((e) => e['id'] == 'home')['teamId'], _home);
    expect(
      timeline.firstWhere((e) => e['detailSource'] == true)['side'],
      'away',
    );
  });

  test('conservative canonical merge: type + team + minute alone never merges real events', () {
    int count(List<Json> events) =>
        mergedMatchTimeline(_match(events), _detail(const [])).length;
    Json goal(
      String id, {
      String? player,
      String? key,
      Map<String, int>? score,
    }) => _ev(
      id,
      'GOAL',
      minute: 30,
      team: _home,
      player: player,
      key: key,
      score: score,
    );
    // A. no players, different upstream ids -> 2.
    expect(count([goal('a1', key: '601'), goal('a2', key: '602')]), 2);
    // No player, no upstream id, no score-after -> keep both.
    expect(count([goal('a3'), goal('a4')]), 2);
    // B. score after 1-0 and 2-0 -> 2.
    expect(
      count([
        goal('b1', score: {'home': 1, 'away': 0}),
        goal('b2', score: {'home': 2, 'away': 0}),
      ]),
      2,
    );
    // C. same canonical player + team + minute -> 1.
    expect(count([goal('c1', player: 'p'), goal('c2', player: 'p')]), 1);
    // D. no player, same score after -> 1.
    expect(
      count([
        goal('d1', score: {'home': 1, 'away': 0}),
        goal('d2', score: {'home': 1, 'away': 0}),
      ]),
      1,
    );
    // E. two cards at the same minute/team without identity -> both.
    expect(
      count([
        _ev('e1', 'YELLOW_CARD', minute: 44, team: _away),
        _ev('e2', 'YELLOW_CARD', minute: 44, team: _away),
      ]),
      2,
    );
    expect(
      count([
        _ev('e3', 'YELLOW_CARD', minute: 44, team: _away, player: 'p1'),
        _ev('e4', 'YELLOW_CARD', minute: 44, team: _away),
      ]),
      2,
    );
    // Two same-minute detail goals keep both canonical twins visible (one-to-one).
    final paired = mergedMatchTimeline(
      _match([goal('x1', key: '701'), goal('x2', key: '702')]),
      _detail([
        {
          'type': 'GOAL',
          'minute': 30,
          'side': 'home',
          'detail': 'Uno',
          'providerEventId': '701',
        },
        {
          'type': 'GOAL',
          'minute': 30,
          'side': 'home',
          'detail': 'Dos',
          'providerEventId': '702',
        },
      ]),
    );
    expect(paired.where((e) => e['type'] == 'GOAL'), hasLength(2));
    // F. synthetic + rich still folds into one.
    expect(
      count([
        _ev('f1', 'GOAL', minute: 23, team: _home, player: 'p'),
        _ev(
          'f2',
          'GOAL',
          minute: 25,
          team: _home,
          synthetic: true,
          score: {'home': 1, 'away': 0},
        ),
      ]),
      1,
    );
  });

  testWidgets(
    'rendered Match Center timeline shows "Gol", never "Marcador actualizado"',
    (tester) async {
      final raw = jsonDecode(
        File('assets/demo.snapshot.json').readAsStringSync(),
      ) as Json;
      final match = _match([
        _ev('ko', 'KICKOFF', minute: 0),
        _ev(
          'syn',
          'GOAL',
          minute: 33,
          team: _away,
          synthetic: true,
          score: {'home': 0, 'away': 1},
          detail: 'Marcador actualizado',
        ),
        _ev('ft', 'FULL_TIME'),
      ]);
      final data = Snapshot({
        ...raw,
        'demo': false,
        'matches': [match.json],
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MatchTimeline(data, match, _detail(const [])),
            ),
          ),
        ),
      );
      expect(find.textContaining('Marcador actualizado'), findsNothing);
      expect(find.text('Gol'), findsOneWidget);
      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .where((t) => t.isNotEmpty)
          .toList();
      expect(
        labels.indexOf(eventLabel('KICKOFF')),
        lessThan(labels.indexOf(eventLabel('FULL_TIME'))),
      );
    },
  );
}

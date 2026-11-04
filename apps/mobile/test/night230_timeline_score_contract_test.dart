import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';

FootballMatch _match(List<Json> events) => FootballMatch({
  'id': 'fb_match_score_contract',
  'homeTeamId': 'fb_team_home',
  'awayTeamId': 'fb_team_away',
  'events': events,
});

Json _canonical({String id = 'event', String? key, String? side = 'home'}) => {
  'id': id,
  'type': 'GOAL',
  'minute': 30,
  if (side != null) 'teamId': 'fb_team_$side',
  'providerEventKey': ?key,
  'score': {'home': 1, 'away': 0},
};

Json _detail({String? key, String? side = 'home'}) => {
  'type': 'GOAL',
  'minute': 30,
  'side': ?side,
  'providerEventId': ?key,
};

List<Json> _merged(List<Json> events, List<Json> incidents) =>
    mergedMatchTimeline(
      _match(events),
      MatchDetail({
        'matchId': 'fb_match_score_contract',
        'incidents': incidents,
      }),
    );

void main() {
  test(
    'an exact event key preserves structured score without player inference',
    () {
      final timeline = _merged(
        [_canonical(key: 'provider-1', side: null)],
        [_detail(key: 'provider-1', side: null)],
      );
      expect(timeline.single['score'], {'home': 1, 'away': 0});
      expect(timeline.single['canonicalPlayerId'], isNull);
    },
  );

  test(
    'a unique known-side occurrence preserves canonical structured score',
    () {
      expect(_merged([_canonical()], [_detail()]).single['score'], {
        'home': 1,
        'away': 0,
      });
    },
  );

  test('explicit detail score null is a correction and prevents fallback', () {
    final row = _merged(
      [_canonical()],
      [
        {..._detail(), 'score': null},
      ],
    ).single;
    expect(row.containsKey('score'), isTrue);
    expect(row['score'], isNull);
  });

  test('an explicit corrected detail score wins', () {
    expect(
      _merged(
        [_canonical(key: 'corrected')],
        [
          {
            ..._detail(key: 'corrected'),
            'score': {'home': 0, 'away': 0},
          },
        ],
      ).single['score'],
      {'home': 0, 'away': 0},
    );
  });

  test('simultaneous anonymous goals never borrow a score by row order', () {
    final timeline = _merged(
      [_canonical(id: 'one', key: '1'), _canonical(id: 'two', key: '2')],
      [_detail(), _detail()],
    );
    expect(timeline, hasLength(2));
    expect(timeline.every((row) => !row.containsKey('score')), isTrue);
  });

  test('an unknown-side anonymous row does not infer the canonical score', () {
    final row = _merged([_canonical(side: null)], [_detail(side: null)]).single;
    expect(row.containsKey('score'), isFalse);
  });
}

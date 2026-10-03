import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/matches/match_period_scores.dart';

FootballMatch _match({
  String status = 'VERIFIED',
  Object? score = const {'home': 3, 'away': 2},
}) => FootballMatch({
  'id': 'match-periods',
  'competitionId': 'competition',
  'homeTeamId': 'home',
  'awayTeamId': 'away',
  'startTime': '2026-10-02T18:00:00Z',
  'status': status,
  'score': ?score,
});

MatchDetail _detail(Object? periods) => MatchDetail({
  'matchId': 'match-periods',
  'available': true,
  'periodScores': ?periods,
});

void main() {
  const half = {'home': 1, 'away': 0};
  const full = {'home': 2, 'away': 1};
  const tiedFull = {'home': 1, 'away': 1};
  const extra = {'home': 1, 'away': 1};
  const shootout = {'home': 4, 'away': 3};

  test('finished match: verified half-time and 90-minute score', () {
    final breakdown = MatchPeriodScores.fromMatch(
      _match(score: const {'home': 2, 'away': 1}),
      _detail(const {'halfTime': half, 'fullTime': full}),
    );
    expect(breakdown?.halfTime?.label, '1 - 0');
    expect(breakdown?.fullTime.label, '2 - 1');
    expect(breakdown?.extraTime, isNull);
    expect(breakdown?.penalties, isNull);
  });

  test('extra-time period goals add to canonical score, shootout does not', () {
    final breakdown = MatchPeriodScores.fromMatch(
      _match(score: const {'home': 2, 'away': 2}),
      _detail(const {
        'halfTime': half,
        'fullTime': tiedFull,
        'extraTime': extra,
        'penalties': shootout,
      }),
    );
    expect(breakdown?.extraTime?.label, '1 - 1');
    expect(breakdown?.penalties?.label, '4 - 3');
  });

  test('shootout can follow a non-tied match score in a two-leg tie', () {
    final breakdown = MatchPeriodScores.fromMatch(
      _match(),
      _detail(const {
        'fullTime': full,
        'extraTime': extra,
        'penalties': shootout,
      }),
    );
    expect(breakdown?.fullTime.label, '2 - 1');
    expect(breakdown?.extraTime?.label, '1 - 1');
    expect(breakdown?.penalties?.label, '4 - 3');
  });

  test('absent, partial and malformed periods never manufacture a row', () {
    expect(MatchPeriodScores.fromMatch(_match(), _detail(null)), isNull);
    expect(
      MatchPeriodScores.fromMatch(_match(), _detail(const {'halfTime': half})),
      isNull,
    );
    expect(
      MatchPeriodScores.fromMatch(
        _match(score: const {'home': 2, 'away': 1}),
        _detail(const {
          'fullTime': full,
          'halfTime': {'home': 1},
        }),
      ),
      isNull,
    );
  });

  test('stale score or impossible half-time hides the entire breakdown', () {
    expect(
      MatchPeriodScores.fromMatch(_match(), _detail(const {'fullTime': full})),
      isNull,
    );
    expect(
      MatchPeriodScores.fromMatch(
        _match(),
        _detail(const {
          'fullTime': full,
          'extraTime': {'home': 0, 'away': 0},
        }),
      ),
      isNull,
    );
    expect(
      MatchPeriodScores.fromMatch(
        _match(score: const {'home': 2, 'away': 1}),
        _detail(const {
          'halfTime': {'home': 3, 'away': 0},
          'fullTime': full,
        }),
      ),
      isNull,
    );
    expect(
      MatchPeriodScores.fromMatch(
        _match(score: const {'home': 2, 'away': 1}),
        _detail(const {
          'fullTime': {'home': -2, 'away': 1},
        }),
      ),
      isNull,
    );
  });

  test('missing canonical score, live and scheduled matches stay hidden', () {
    final detail = _detail(const {'fullTime': full});
    expect(MatchPeriodScores.fromMatch(_match(score: null), detail), isNull);
    expect(
      MatchPeriodScores.fromMatch(
        _match(status: 'LIVE', score: const {'home': 2, 'away': 1}),
        detail,
      ),
      isNull,
    );
    expect(
      MatchPeriodScores.fromMatch(
        _match(status: 'SCHEDULED', score: const {'home': 2, 'away': 1}),
        detail,
      ),
      isNull,
    );
  });

  testWidgets('card labels only the periods actually supplied', (tester) async {
    final fullOnly = MatchPeriodScores.fromMatch(
      _match(score: const {'home': 2, 'away': 1}),
      _detail(const {'fullTime': full}),
    )!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MatchPeriodScoresCard(scores: fullOnly)),
      ),
    );
    expect(find.text("90'"), findsOneWidget);
    expect(find.text('Descanso'), findsNothing);
    expect(find.text('Prórroga (goles)'), findsNothing);
    expect(find.text('Penales'), findsNothing);

    final all = MatchPeriodScores.fromMatch(
      _match(score: const {'home': 2, 'away': 2}),
      _detail(const {
        'halfTime': half,
        'fullTime': tiedFull,
        'extraTime': extra,
        'penalties': shootout,
      }),
    )!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MatchPeriodScoresCard(scores: all)),
      ),
    );
    for (final label in ['Descanso', "90'", 'Prórroga (goles)', 'Penales']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('4 - 3'), findsOneWidget);
  });
}

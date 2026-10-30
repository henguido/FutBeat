import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/match_prefetch_plan.dart';
import 'package:futbeat/core/models.dart';

FootballMatch fixture(
  String id,
  String competition,
  String home,
  String away,
) => FootballMatch({
  'id': id,
  'competitionId': competition,
  'homeTeamId': home,
  'awayTeamId': away,
  'startTime': '2026-10-30T18:00:00Z',
  'status': 'SCHEDULED',
});

void main() {
  test('does not fetch detail for unrelated calendar fixtures', () {
    final plan = MatchPrefetchPlan.build(
      matches: [fixture('unrelated', 'x', 'a', 'b')],
      follows: const {},
      selectedCountry: null,
      competitions: const {},
    );
    expect(plan.matchIds, isEmpty);
  });

  test(
    'prioritizes open match, follows, country, highlights and bounds work',
    () {
      final matches = [
        fixture('other', 'eng', 'a', 'b'),
        fixture('highlight', 'eng', 'c', 'd'),
        fixture('country', 'cr', 'e', 'f'),
        fixture('league', 'es', 'g', 'h'),
        fixture('team', 'eng', 'fav', 'i'),
        fixture('open', 'eng', 'j', 'k'),
        fixture('team', 'eng', 'fav', 'i'),
      ];
      final plan = MatchPrefetchPlan.build(
        matches: matches,
        follows: {'team:fav', 'competition:es'},
        selectedCountry: 'CR',
        competitions: {
          'cr': Entity({'id': 'cr', 'name': 'Costa Rica', 'countryCode': 'CR'}),
        },
        openMatchId: 'open',
        highlightedMatchIds: {'highlight'},
        maxMatches: 5,
      );
      expect(plan.matchIds, ['open', 'team', 'league', 'country', 'highlight']);
    },
  );

  test(
    'stops before the next request after cancellation and never retries',
    () async {
      final plan = MatchPrefetchPlan.build(
        matches: [fixture('a', 'x', 'a', 'b'), fixture('b', 'x', 'c', 'd')],
        follows: const {'team:a', 'team:c'},
        selectedCountry: null,
        competitions: const {},
      );
      var active = true;
      final requests = <String>[];
      final count = await runMatchPrefetch(
        plan,
        isActive: () => active,
        fetch: (id) async {
          requests.add(id);
          active = false;
          throw StateError('offline');
        },
      );
      expect(count, 1);
      expect(requests, ['a']);
    },
  );

  test('enforces local budget even when plan is larger', () async {
    final plan = MatchPrefetchPlan.build(
      matches: [for (var i = 0; i < 20; i++) fixture('$i', 'x', 'a', 'b')],
      follows: {'team:a'},
      selectedCountry: null,
      competitions: const {},
    );
    final requests = <String>[];
    final count = await runMatchPrefetch(
      plan,
      isActive: () => true,
      maxRequests: 2,
      fetch: (id) async => requests.add(id),
    );
    expect(count, 2);
    expect(requests.length, 2);
  });
}

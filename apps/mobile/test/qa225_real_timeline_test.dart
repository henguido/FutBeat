import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';

void main() {
  test(
    'A32 real cached context and detail retain every sporting occurrence',
    () {
      final fixture = jsonDecode(
        File('test/fixtures/everton_newcastle_qa225_timeline.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>;
      final match = FootballMatch(Map<String, dynamic>.from(fixture['match']));
      final detail = MatchDetail(Map<String, dynamic>.from(fixture['detail']));
      final timeline = mergedMatchTimeline(match, detail);
      expect(match.events, hasLength(25));
      expect(detail.incidents, hasLength(22));
      expect(timeline, hasLength(25));
      for (final entry in {
        'GOAL': 4,
        'YELLOW_CARD': 8,
        'SUBSTITUTION': 10,
        'KICKOFF': 1,
        'HALFTIME': 1,
        'FULL_TIME': 1,
      }.entries) {
        expect(
          timeline.where((event) => event['type'] == entry.key),
          hasLength(entry.value),
          reason: entry.key,
        );
      }
      final expected = detail.incidents
          .map((event) => event['providerEventId'])
          .toSet();
      final actual = timeline
          .map((event) => event['providerEventId'])
          .whereType<String>()
          .toSet();
      expect(actual, containsAll(expected));
      expect(expected, hasLength(22));
      for (final source in detail.incidents.where(
        (event) => event['type'] == 'SUBSTITUTION',
      )) {
        final row = timeline.singleWhere(
          (event) => event['providerEventId'] == source['providerEventId'],
        );
        expect(row['outPlayerId'], source['outPlayerId']);
        expect(row['inPlayerId'], source['inPlayerId']);
      }
      // Three away substitutions at 46': minute/side cannot identify which
      // canonical player belongs to which provider row. Keep the supplied
      // provider identities, but never attach a positional canonical guess.
      for (final row in timeline.where(
        (event) => event['type'] == 'SUBSTITUTION' && event['minute'] == 46,
      )) {
        expect(row['canonicalPlayerId'], isNull);
        expect(row['canonicalAssistPlayerId'], isNull);
      }
    },
  );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/global_schedule.dart';
import 'package:futbeat/core/models.dart';

Snapshot _base({bool withCupMatch = false}) {
  final start = DateTime.utc(2026, 9, 18, 0, 30);
  return Snapshot({
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': DateTime.utc(2026, 9, 17, 20).toIso8601String(),
    'coverage': {
      'source': 'FutBeat backend',
      'partial': true,
      'live': false,
    },
    'freshness': {'stale': false},
    'competitions': [
      {
        'id': 'fb_comp_cr',
        'name': 'Liga FPD',
        'country': 'Costa Rica',
      },
      if (withCupMatch)
        {
          'id': 'fb_comp_cac',
          'name': 'CONCACAF Central American Cup',
          'country': 'CONCACAF',
        },
    ],
    'teams': [
      {
        'id': 'fb_team_lda',
        'name': 'Alajuelense',
        'shortName': 'LDA',
        'country': 'Costa Rica',
        'aliases': <String>[],
      },
      if (withCupMatch)
        {
          'id': 'fb_team_mar',
          'name': 'Marathón',
          'shortName': 'MAR',
          'country': 'Honduras',
          'aliases': <String>[],
        },
    ],
    'players': <dynamic>[],
    'matches': [
      if (withCupMatch)
        {
          'id': 'fb_match_existing',
          'competitionId': 'fb_comp_cac',
          'homeTeamId': 'fb_team_lda',
          'awayTeamId': 'fb_team_mar',
          'startTime': start.toIso8601String(),
          'status': 'SCHEDULED',
          'score': null,
          'minute': null,
          'events': <dynamic>[],
          'statistics': <dynamic>[],
        },
    ],
    'standings': <dynamic>[],
  });
}

Map<String, dynamic> _event({
  required int id,
  required int tournamentId,
  required String tournament,
  required String country,
  required int homeId,
  required String home,
  String homeCode = '',
  required int awayId,
  required String away,
  String awayCode = '',
  required DateTime start,
}) =>
    {
      'id': id,
      'startTimestamp': start.millisecondsSinceEpoch ~/ 1000,
      'status': {'type': 'notstarted', 'description': 'Not started'},
      'tournament': {
        'id': tournamentId + 100000,
        'name': tournament,
        'category': {'name': country},
        'uniqueTournament': {'id': tournamentId, 'name': tournament},
      },
      'homeTeam': {
        'id': homeId,
        'name': home,
        'nameCode': homeCode,
      },
      'awayTeam': {
        'id': awayId,
        'name': away,
        'nameCode': awayCode,
      },
    };

void main() {
  test('global schedule keeps unknown competitions and reuses followed team identity', () {
    final receivedAt = DateTime.utc(2026, 9, 17, 21);
    final merged = mergeGlobalSchedule(
      _base(),
      [
        _event(
          id: 9001,
          tournamentId: 4739,
          tournament: 'CONCACAF Central American Cup',
          country: 'CONCACAF',
          homeId: 1,
          home: 'LD Alajuelense',
          homeCode: 'LDA',
          awayId: 2,
          away: 'Marathón',
          awayCode: 'MAR',
          start: DateTime.utc(2026, 9, 18, 0, 30),
        ),
        _event(
          id: 9002,
          tournamentId: 999999,
          tournament: 'Completely Unknown League',
          country: 'Exampleland',
          homeId: 300,
          home: 'Example FC',
          homeCode: 'EXA',
          awayId: 301,
          away: 'Another FC',
          awayCode: 'ANO',
          start: DateTime.utc(2026, 9, 18, 2),
        ),
      ],
      receivedAt,
    );

    expect(merged.matches, hasLength(2));
    expect(
      merged.competitions.any((item) => item.name == 'Completely Unknown League'),
      isTrue,
    );

    final ldaMatch = merged.matches.firstWhere(
      (item) => merged.team(item.homeId)?.name == 'Alajuelense',
    );
    expect(ldaMatch.homeId, 'fb_team_lda');
    expect(merged.coverage?['source'], 'FutBeat Global Beta');
  });

  test('global schedule does not duplicate a canonical fixture already stored', () {
    final merged = mergeGlobalSchedule(
      _base(withCupMatch: true),
      [
        _event(
          id: 9001,
          tournamentId: 4739,
          tournament: 'CONCACAF Central American Cup',
          country: 'CONCACAF',
          homeId: 1,
          home: 'LD Alajuelense',
          homeCode: 'LDA',
          awayId: 2,
          away: 'Marathón',
          awayCode: 'MAR',
          start: DateTime.utc(2026, 9, 18, 0, 30),
        ),
      ],
      DateTime.utc(2026, 9, 17, 21),
    );

    expect(merged.matches, hasLength(1));
    expect(merged.matches.single.id, 'fb_match_existing');
  });
}

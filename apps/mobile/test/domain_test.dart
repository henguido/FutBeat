import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';

void main() {
  test('calendar dates are evaluated in America/Costa_Rica', () {
    expect(
      costaRicaTime(DateTime.parse('2026-09-17T05:30:00Z')),
      DateTime.utc(2026, 9, 16, 23, 30),
    );
    expect(
      costaRicaTime(DateTime.parse('2026-09-17T06:30:00Z')),
      DateTime.utc(2026, 9, 17, 0, 30),
    );
  });
  final json =
      jsonDecode(File('assets/demo.snapshot.json').readAsStringSync()) as Json;
  final data = Snapshot(json);
  test('FB-US-001/002: filters use local calendar date and status', () {
    final match = data.matches.first;
    expect(
      data.onDate(match.startTime, 'En vivo').map((m) => m.id),
      contains(match.id),
    );
    expect(data.onDate(DateTime(2020), 'Todos'), isEmpty);
    expect(
      data.onDate(match.startTime, 'Próximos').every((m) => m.isUpcoming),
      isTrue,
    );
  });
  test('FB-US-004: every event player and match entity resolves', () {
    for (final match in data.matches) {
      expect(data.team(match.homeId), isNotNull);
      expect(data.competition(match.competitionId), isNotNull);
      for (final event in match.events) {
        expect(data.player(event['playerId'] as String), isNotNull);
      }
    }
  });
  test('FB-US-042: aliases find canonical teams', () {
    expect(
      data.teams.where((e) => e.matches('  LDA  ')).single.id,
      'fb_team_lda',
    );
    expect(
      data.teams.where((e) => e.matches('sapri')).single.id,
      'fb_team_sap',
    );
  });
  test('a match with a missing team or competition is dropped, not fatal', () {
    final broken = Snapshot({
      ...json,
      'matches': [
        ...(json['matches'] as List),
        {
          'id': 'fb_match_orphan',
          'competitionId': 'fb_comp_missing',
          'homeTeamId': (json['teams'] as List).first['id'],
          'awayTeamId': 'fb_team_missing',
          'startTime': '2026-09-20T18:00:00Z',
          'status': 'SCHEDULED',
          'events': <dynamic>[],
          'statistics': <dynamic>[],
        },
      ],
    });
    expect(broken.match('fb_match_orphan'), isNull);
    expect(broken.matches.length, (json['matches'] as List).length);
  });
  test('unknown IDs are safe and unsupported contract fails', () {
    expect(data.match('missing'), isNull);
    expect(
      () => Snapshot({...json, 'schemaVersion': 99}),
      throwsFormatException,
    );
  });
  test('FB-US-057: unverified image is not rendered', () {
    expect(
      Entity({
        'id': 'x',
        'name': 'X',
        'media': {
          'url': 'https://example.com/a.png',
          'verificationStatus': 'UNVERIFIED',
        },
      }).imageUrl,
      isNull,
    );
  });
}

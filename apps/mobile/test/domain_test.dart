import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';

void main() {
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

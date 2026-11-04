import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/entities/player_profile.dart';

void main() {
  test('stored QA225 substitution retains incoming player club fixture without counting an assist', () {
    final fixture = jsonDecode(
      File('test/fixtures/everton_newcastle_qa225_timeline.json')
          .readAsStringSync(),
    ) as Json;
    final match = Map<String, dynamic>.from(fixture['match']);
    final event = (match['events'] as List).cast<Json>().firstWhere(
      (event) => event['type'] == 'SUBSTITUTION',
    );
    final incoming = event['assistPlayerId'] as String;
    final outgoing = event['playerId'] as String;
    match['events'] = [event];
    final data = Snapshot({
      'schemaVersion': 1,
      'demo': false,
      'updatedAt': '2026-11-03T12:00:00Z',
      'teams': [
        for (final id in [
          match['homeTeamId'],
          match['awayTeamId'],
          'fb_selection261',
        ])
          {'id': id, 'name': 'Equipo de fixture'},
      ],
      'competitions': [
        {'id': match['competitionId'], 'name': 'Competición de fixture'},
      ],
      'players': [
        for (final id in [incoming, outgoing, 'fb_homonym261'])
          {'id': id, 'name': 'Nombre controlado', 'teamId': 'fb_selection261'},
      ],
      'matches': [match],
      'standings': [],
    });
    for (final id in [incoming, outgoing]) {
      expect(
        playerProfileMatches(data, data.player(id)!).map((match) => match.id),
        [match['id']],
      );
      final activity = playerRecentEvents(data, id);
      expect(activity, hasLength(1));
      expect(activity.single.$2['id'], event['id']);
      expect(
        activity.single.$3,
        isFalse,
        reason: 'A substitution is never a goal assist',
      );
    }
    expect(playerRecentEvents(data, 'fb_homonym261'), isEmpty);
    expect(playerProfileMatches(data, data.player('fb_homonym261')!), isEmpty);
  });
}

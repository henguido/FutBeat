import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/entities/player_profile.dart';

// QA81 (#222): a club goalscorer who is also a national-team player sees the
// matches of both teams, and the matches where they have an event of their
// own. Nothing is matched by name.

Map<String, dynamic> _match(
  String id,
  String home,
  String away,
  String start, {
  List<Map<String, dynamic>> events = const [],
}) => {
  'id': id,
  'competitionId': 'fb_comp',
  'homeTeamId': home,
  'awayTeamId': away,
  'startTime': start,
  'status': 'VERIFIED',
  'score': {'home': 1, 'away': 0},
  'events': events,
  'statistics': <dynamic>[],
};

Snapshot _snapshot(Map<String, dynamic> player) => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-10-19T12:00:00Z',
  'competitions': [
    {'id': 'fb_comp', 'name': 'Liga', 'country': 'Costa Rica'},
  ],
  'teams': [
    for (final id in ['fb_club', 'fb_nat', 'fb_rival', 'fb_other'])
      {'id': id, 'name': id, 'country': 'Costa Rica'},
  ],
  'players': [
    {'id': 'fb_player', 'name': 'Sebastián Ejemplo', ...player},
    {'id': 'fb_homonym', 'name': 'Sebastián Ejemplo', 'teamId': 'fb_other'},
  ],
  'standings': <dynamic>[],
  'matches': [
    _match('club', 'fb_club', 'fb_rival', '2026-10-18T22:00:00Z'),
    _match('nat', 'fb_nat', 'fb_rival', '2026-10-10T02:00:00Z'),
    _match('other', 'fb_other', 'fb_rival', '2026-10-17T22:00:00Z'),
    _match(
      'event_only',
      'fb_rival',
      'fb_other',
      '2026-10-05T22:00:00Z',
      events: [
        {'id': 'e1', 'type': 'GOAL', 'minute': 9, 'playerId': 'fb_player'},
      ],
    ),
  ],
});

List<String> _ids(Snapshot data) =>
    playerMatches(data, data.player('fb_player')!).map((m) => m.id).toList();

void main() {
  test('server teamIds: club and national-team matches, oldest first', () {
    final data = _snapshot({
      'teamId': 'fb_club',
      'teamIds': ['fb_club', 'fb_nat'],
    });
    expect(_ids(data), ['event_only', 'nat', 'club']);
  });

  test('older server: teamId + nationalTeamId still cover both', () {
    final data = _snapshot({'teamId': 'fb_club', 'nationalTeamId': 'fb_nat'});
    expect(_ids(data), ['event_only', 'nat', 'club']);
  });

  test('teamId pointing at the national team keeps own-event club games', () {
    final data = _snapshot({'teamId': 'fb_nat'});
    expect(_ids(data), ['event_only', 'nat']);
  });

  test('a homonym on another team never lends its matches', () {
    final data = _snapshot({'teamId': 'fb_club'});
    expect(_ids(data), isNot(contains('other')));
    expect(
      playerMatches(data, data.player('fb_homonym')!).map((m) => m.id).toList(),
      ['event_only', 'other'],
    );
  });

  test('playerTeamIds de-duplicates and keeps the server order', () {
    final data = _snapshot({
      'teamId': 'fb_club',
      'nationalTeamId': 'fb_nat',
      'teamIds': ['fb_club', 'fb_nat', 'fb_club'],
    });
    expect(playerTeamIds(data.player('fb_player')!), ['fb_club', 'fb_nat']);
  });
}

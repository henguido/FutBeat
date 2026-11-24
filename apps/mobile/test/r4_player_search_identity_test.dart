import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/player_display_identity.dart';
import 'package:futbeat/features/explore/explore_screen.dart';

import 'r3_match_center_regressions_test.dart' show fixture;

void main() {
  final sparse = <String, dynamic>{'id': 'fb_player_same', 'name': 'Jugador'};
  final rich = <String, dynamic>{
    ...sparse,
    'teamId': 'fb_home',
    'position': 'Forward',
    'country': 'CR',
    'dateOfBirth': '1990-01-01',
    'media': {
      'url': 'https://example.test/player.png',
      'verificationStatus': 'VERIFIED',
    },
  };
  for (final reverse in [false, true]) {
    test(
      'R4 same canonical ID keeps richest row and profile lookup regardless of order $reverse',
      () {
        final rows = reverse ? [rich, sparse] : [sparse, rich];
        final base = fixture('SCHEDULED');
        final data = Snapshot({
          'schemaVersion': 1,
          'demo': false,
          'updatedAt': base.updatedAt.toIso8601String(),
          'teams': base.teams.map((e) => e.json).toList(),
          'competitions': base.competitions.map((e) => e.json).toList(),
          'matches': [],
          'standings': [],
          'players': rows,
        });
        expect(data.players, hasLength(1));
        expect(
          data.player('fb_player_same')!.imageUrl,
          'https://example.test/player.png',
        );
        expect(data.player('fb_player_same')!.json['position'], 'Forward');
        expect(
          suggestAvailablePlayers(
            remote: [Entity(sparse)],
            loaded: [Entity(rich)],
            follows: {},
          ).single.imageUrl,
          isNotNull,
        );
        expect(presentPlayers(rows).single['position'], 'Forward');
      },
    );
  }
  test(
    'R4 distinct IDs including true homonyms remain separate and retain clubs',
    () {
      final rows = uniquePlayerEntities([
        Entity(rich),
        Entity({...rich, 'id': 'fb_player_other', 'teamId': 'fb_away'}),
      ]);
      expect(rows.map((e) => e.id), ['fb_player_same', 'fb_player_other']);
      expect(rows.map((e) => e.json['teamId']), ['fb_home', 'fb_away']);
    },
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/last_confirmed_lineups.dart';
import 'package:futbeat/features/matches/match_screen.dart';

import 'last_confirmed_lineups_test.dart' as history;

Json unknown(String name, {Object key = '0'}) => {
  'id': key,
  'canonicalId': 'fb_player_wrong_cached',
  'name': name,
  'image': 'https://fixture.invalid/wrong-player.png',
  'rating': 7.1,
};
void main() {
  for (final key in <Object>['0', '00', ' 000 ', 0, 0.0]) {
    test(
      'unknown provider key $key cannot supply another player photo',
      () => expect(playerImage(unknown('Sin identificar', key: key)), isNull),
    );
  }
  test('unknown keys never attribute personal events or minutes', () {
    final row = unknown('Sin identificar');
    final incidents = <Json>[
      {
        'type': 'GOAL',
        'minute': 20,
        'side': 'home',
        'playerId': '0',
        'canonicalPlayerId': 'fb_player_wrong_cached',
      },
      {
        'type': 'SUBSTITUTION',
        'minute': 65,
        'side': 'home',
        'outPlayerId': '0',
      },
    ];
    expect(lineupEventsForPlayer(row, incidents, 'home'), isEmpty);
    expect(
      playerMinutesPlayed(
        row,
        MatchDetail({
          'matchId': 'fb_match_zero',
          'home': {
            'starters': [row],
          },
          'incidents': incidents,
        }),
        'home',
      ),
      isNull,
    );
  });
  test('unknown rows sharing the old bad canonical ID remain separate', () {
    final detail = MatchDetail({
      'matchId': 'fb_match_zero',
      'home': {
        'starters': [unknown('Uno'), unknown('Dos')],
      },
    });
    expect(detail.topRated(limit: 10), hasLength(2));
  });
  test('real provider IDs preserve homonyms; canonical duplicates remain deduplicated', () {
    final detail = MatchDetail({
      'matchId': 'fb_match_ids',
      'home': {
        'starters': [
          {'id': '101', 'name': 'Mismo', 'rating': 7.2},
          {'id': '102', 'name': 'Mismo', 'rating': 7.1},
          {
            'id': '103',
            'canonicalId': 'fb_player_real',
            'name': 'Real',
            'rating': 8.0,
          },
          {
            'id': '104',
            'canonicalId': 'fb_player_real',
            'name': 'Real repetido',
            'rating': 8.0,
          },
        ],
      },
    });
    expect(detail.topRated(limit: 10), hasLength(3));
  });
  test(
    'historical legacy zero keys do not erase a whole side or create a profile',
    () {
      final raw = history.payload();
      for (final row in raw['home']['lineups']) {
        row['playerKey'] = '0';
        row['playerId'] = 'fb_player_wrong_cached';
      }
      final side = LastConfirmedLineups.parse(
        raw,
        history.targetId,
      ).side('home', history.target(), history.snapshot());
      expect(side, isNotNull);
      expect(side!.starters, hasLength(11));
      expect(
        [...side.starters, ...side.bench].every((p) => !p.containsKey('id')),
        isTrue,
      );
    },
  );
  test('K0 null keys retain every historical starter and substitute', () {
    final raw = history.payload();
    // Mimic JSON deserialization rather than non-nullable Dart map inference.
    final rows = raw['home']['lineups'] as List;
    raw['home']['lineups'] = [
      for (final row in rows)
        <String, dynamic>{...row, 'playerKey': null, 'playerId': null},
    ];
    final side = LastConfirmedLineups.parse(
      raw,
      history.targetId,
    ).side('home', history.target(), history.snapshot())!;
    expect(side.starters, hasLength(11));
    expect(side.bench, hasLength(2));
    expect(side.starters.every((p) => !p.containsKey('id')), isTrue);
  });
  test(
    'blank historic provider keys are absent identities, not duplicates',
    () {
      final raw = history.payload();
      for (final row in raw['home']['lineups']) {
        row['playerKey'] = '';
      }
      final side = LastConfirmedLineups.parse(
        raw,
        history.targetId,
      ).side('home', history.target(), history.snapshot());
      expect(side?.starters, hasLength(11));
    },
  );
  testWidgets('an old poisoned zero-key cache cannot offer Ver perfil', (
    tester,
  ) async {
    final row = unknown('Jugador desconocido')..remove('image');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showMatchPlayerSheet(context, row, 'home'),
              child: const Text('Abrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
    expect(find.text('Jugador desconocido'), findsWidgets);
    expect(find.text('Ver perfil'), findsNothing);
  });
}

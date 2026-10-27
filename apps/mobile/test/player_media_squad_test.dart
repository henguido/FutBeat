import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/entity_media.dart';
import 'package:futbeat/features/entities/team_profile.dart';
import 'package:futbeat/features/matches/match_screen.dart';
import 'package:futbeat/shared/widgets.dart';

void main() {
  testWidgets('squad profile and lineup reuse verified canonical photo', (
    tester,
  ) async {
    final memory = EntityMediaMemory();
    addTearDown(memory.dispose);
    memory.absorb(
      Snapshot({
        'schemaVersion': 1,
        'demo': false,
        'updatedAt': '2026-10-25T00:00:00Z',
        'teams': [],
        'competitions': [],
        'matches': [],
        'standings': [],
        'players': [
          {
            'id': 'fb_player_shared',
            'name': 'Jugador Compartido',
            'media': {
              'verificationStatus': 'VERIFIED',
              'url': 'https://media.example.test/shared.png',
            },
          },
        ],
      }),
    );
    final sparsePlayer = Entity({
      'id': 'fb_player_shared',
      'name': 'Jugador Compartido',
    });
    await tester.pumpWidget(
      MaterialApp(
        home: EntityMediaScope(
          memory: memory,
          child: Scaffold(
            body: Column(
              children: [
                PlayerPhoto(sparsePlayer, size: 40),
                PlayerPhoto(sparsePlayer, size: 84),
                Builder(
                  builder: (context) {
                    final image = lineupPlayerImageOf(context, {
                      'canonicalId': 'fb_player_shared',
                      'name': 'Jugador Compartido',
                    });
                    return Text(image ?? 'sin foto');
                  },
                ),
                Builder(
                  builder: (context) {
                    final image = lineupPlayerImageOf(context, {
                      'id': 'fb_player_shared',
                      'name': 'Jugador Compartido',
                    });
                    return Text(
                      image ?? 'sin foto',
                      key: const Key('id-photo'),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.byType(Image), findsNWidgets(2));
    expect(
      find.text('https://media.example.test/shared.png'),
      findsNWidgets(2),
    );
    expect(find.byKey(const Key('id-photo')), findsOneWidget);
    for (final image in tester.widgetList<Image>(find.byType(Image))) {
      final provider = image.image is ResizeImage
          ? (image.image as ResizeImage).imageProvider
          : image.image;
      expect(
        (provider as NetworkImage).url,
        'https://media.example.test/shared.png',
      );
    }
    // A later partial snapshot omits media; omission is not revocation.
    memory.absorb(
      Snapshot({
        'schemaVersion': 1,
        'demo': false,
        'updatedAt': '2026-10-25T00:01:00Z',
        'teams': [],
        'competitions': [],
        'matches': [],
        'standings': [],
        'players': [
          {'id': 'fb_player_shared', 'name': 'Jugador Compartido'},
        ],
      }),
    );
    await tester.pump();
    expect(find.byType(Image), findsNWidgets(2));
  });
  test('canonical verified player media wins over lineup fallback', () {
    expect(
      playerImage({
        'media': {
          'verificationStatus': 'VERIFIED',
          'url': 'https://media.goal-api.com/canonical.png',
        },
        'image': 'https://media.goal-api.com/lineup.png',
      }),
      'https://media.goal-api.com/canonical.png',
    );
    expect(
      playerImage({'image': 'https://media.goal-api.com/lineup.png'}),
      'https://media.goal-api.com/lineup.png',
    );
    expect(
      playerImage({
        'media': {
          'verificationStatus': 'PROVISIONAL',
          'url': 'https://media.goal-api.com/unverified.png',
        },
      }),
      isNull,
    );
  });
  test('unsafe or absent photo falls back without a provider request', () {
    for (final value in [
      null,
      '',
      'http://media.goal-api.com/a.png',
      'javascript:alert(1)',
      'https://user:secret@example.com/a.png',
      123,
    ]) {
      expect(safePlayerImage(value), isNull);
      expect(playerImage({'image': value}), isNull);
    }
  });
  testWidgets(
    'missing or invalid player photo shows initials with no image or spinner',
    (tester) async {
      final entity = Entity({
        'id': 'fb_player_test',
        'name': ' Ana  Gol ',
        'shortName': '',
        'media': {
          'verificationStatus': 'VERIFIED',
          'url': 'http://bad.invalid/photo.png',
        },
      });
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: EntityAvatar(entity))),
      );
      expect(find.text('AG'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      expect(
        Entity({'id': 'fb_player_empty', 'name': '', 'shortName': ''}).initials,
        '·',
      );
    },
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/shared/widgets.dart';

void main() {
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

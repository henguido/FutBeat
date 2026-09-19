import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/matches/match_screen.dart';

void main() {
  test('match detail exposes verified post-match videos', () {
    final detail = MatchDetail({
      'matchId': 'fb_match_video',
      'available': true,
      'pending': false,
      'detailLevel': 'full',
      'home': <String, dynamic>{},
      'away': <String, dynamic>{},
      'statistics': <dynamic>[],
      'incidents': <dynamic>[],
      'videos': [
        {
          'videoId': 'abcDEF12345',
          'title': 'Saprissa vs Alajuelense | Resumen',
          'url': 'https://www.youtube.com/watch?v=abcDEF12345',
          'channelId': 'UC1234567890123456789012',
          'channelName': 'Canal oficial',
          'source': 'YouTube · canal oficial',
          'verificationStatus': 'VERIFIED_CHANNEL',
        },
      ],
    });

    expect(detail.videos, hasLength(1));
    expect(detail.videos.first['videoId'], 'abcDEF12345');
    expect(
      detail.videos.first['verificationStatus'],
      'VERIFIED_CHANNEL',
    );
  });

  testWidgets('post-match video card shows verified source and copy action', (
    tester,
  ) async {
    final detail = MatchDetail({
      'matchId': 'fb_match_video',
      'available': true,
      'pending': false,
      'detailLevel': 'full',
      'home': <String, dynamic>{},
      'away': <String, dynamic>{},
      'statistics': <dynamic>[],
      'incidents': <dynamic>[],
      'videos': [
        {
          'videoId': 'abcDEF12345',
          'title': 'Saprissa vs Alajuelense | Resumen',
          'url': 'https://www.youtube.com/watch?v=abcDEF12345',
          'channelId': 'UC1234567890123456789012',
          'channelName': 'Canal oficial',
          'source': 'YouTube · canal oficial',
          'verificationStatus': 'VERIFIED_CHANNEL',
        },
      ],
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PostMatchVideos(detail),
        ),
      ),
    );

    expect(
      find.text('Saprissa vs Alajuelense | Resumen'),
      findsOneWidget,
    );
    expect(
      find.text('Canal oficial · YouTube · canal oficial'),
      findsOneWidget,
    );
    expect(
      find.byTooltip('Copiar enlace de YouTube'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

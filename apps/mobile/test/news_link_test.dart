import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/news_links.dart';
import 'package:futbeat/shared/widgets.dart';

const _article = <String, dynamic>{
  'title': 'Comunicado oficial',
  'sourceName': 'Club Uno',
  'publishedAt': '2026-10-19T09:00:00Z',
  'url': 'https://club.example/noticias/uno',
};

void main() {
  final validRights = <String, dynamic>{
    'status': 'ALLOWED',
    'verified': true,
    'expiresAt': '2099-01-01T00:00:00Z',
  };

  test('media requires explicit verified and strictly valid future expiry', () {
    final now = DateTime.utc(2026, 10, 23);
    expect(newsMediaAuthorized(validRights, now: now), isTrue);
    for (final expiry in [
      null,
      '',
      'invalid',
      '2099-02-30T00:00:00Z',
      '2099-01-01',
      '2020-01-01T00:00:00Z',
      '2026-10-23T00:00:00Z',
    ]) {
      expect(
        newsMediaAuthorized({...validRights, 'expiresAt': expiry}, now: now),
        isFalse,
        reason: '$expiry',
      );
    }
    for (final rights in [
      null,
      'ALLOWED',
      {...validRights, 'verified': false},
      {...validRights, 'status': 'DENIED'},
    ]) {
      expect(newsMediaAuthorized(rights, now: now), isFalse);
    }
  });

  testWidgets(
    'authorized image renders and load failure leaves no empty frame',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NewsArticleCard({
              ..._article,
              'imageUrl': 'https://club.example/authorized.jpg',
              'rights': {'image': validRights},
            }),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('news-image')), findsOneWidget);
      final image = tester.widget<Image>(
        find.byKey(const ValueKey('news-image')),
      );
      expect(
        (image.image as NetworkImage).url,
        'https://club.example/authorized.jpg',
      );
      // Exercise the successful frame path separately from test HTTP (always 400).
      final frame = image.frameBuilder!(
        tester.element(find.byKey(const ValueKey('news-image'))),
        const SizedBox(),
        0,
        true,
      );
      expect(frame, isA<Padding>());
      await tester.pumpAndSettle();
      expect(find.byType(AspectRatio), findsNothing);
      expect(find.text('Comunicado oficial'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final expiry in [
    null,
    'invalid',
    '2099-02-30T00:00:00Z',
    '2020-01-01T00:00:00Z',
  ]) {
    testWidgets('unverifiable media is hidden: $expiry', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NewsArticleCard({
              ..._article,
              'imageUrl': 'https://club.example/protected.jpg',
              'description': 'Protected excerpt',
              'rights': {
                'image': {...validRights, 'expiresAt': expiry},
                'snippet': {...validRights, 'expiresAt': expiry},
              },
            }),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('news-image')), findsNothing);
      expect(find.text('Protected excerpt'), findsNothing);
    });
  }

  test('only public HTTPS links are accepted', () {
    expect(safeNewsUri(_article['url'])?.host, 'club.example');
    for (final value in [
      null,
      '',
      'http://club.example/a',
      'javascript:alert(1)',
      'https://user:pass@club.example/a',
      'https://localhost/a',
      'https://127.0.0.1/a',
      'https://club.local/a',
      'https://club.example\\@other.example/a',
      'https://club.example/a b',
      '/noticias/uno',
    ]) {
      expect(safeNewsUri(value), isNull, reason: '$value');
    }
  });

  testWidgets('card opens original URL on tap without copying it', (
    tester,
  ) async {
    final opened = <Uri>[];
    var copies = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copies++;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NewsArticleCard(
            _article,
            openLink: (uri) async {
              opened.add(uri);
              return true;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Comunicado oficial'));
    await tester.pump();
    expect(opened.map((uri) => uri.toString()), [
      'https://club.example/noticias/uno',
    ]);
    expect(copies, 0);
    await tester.tap(find.byKey(const ValueKey('news-copy-link')));
    await tester.pump();
    expect(opened, hasLength(1));
    expect(copies, 1);
  });

  testWidgets('invalid or missing link has no open or copy action', (
    tester,
  ) async {
    var opens = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NewsArticleCard(
            {..._article, 'url': 'javascript:alert(1)'},
            openLink: (_) async {
              opens++;
              return true;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Comunicado oficial'));
    await tester.pump();
    expect(opens, 0);
    expect(find.byKey(const ValueKey('news-copy-link')), findsNothing);
  });

  testWidgets('failed browser open is reported without copying', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NewsArticleCard(_article, openLink: (_) async => false),
        ),
      ),
    );
    await tester.tap(find.text('Comunicado oficial'));
    await tester.pump();
    expect(find.text('No se pudo abrir el artículo'), findsOneWidget);
  });

  testWidgets('rights-omitted image and snippet remain absent', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NewsArticleCard({
            ..._article,
            'imageUrl': 'https://club.example/unlicensed.jpg',
            'description': 'Protected excerpt',
          }),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('news-image')), findsNothing);
    expect(find.text('Protected excerpt'), findsNothing);
    expect(find.text('Club Uno · 19/10/2026'), findsOneWidget);
  });
}

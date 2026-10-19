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
      const MaterialApp(home: Scaffold(body: NewsArticleCard(_article))),
    );
    expect(find.byKey(const ValueKey('news-image')), findsNothing);
    expect(find.text('Club Uno · 19/10/2026'), findsOneWidget);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/features/news/news_feed_adapter.dart';
import 'package:futbeat/features/news/news_screen.dart';

Map<String, dynamic> _story(String id, {String category = 'GENERAL'}) => {
  'clusterId': id,
  'title': 'Comunicado $id',
  'url': 'https://club.example/$id',
  'sourceName': 'Club Uno',
  'publishedAt': '2026-10-19T09:00:00Z',
  'category': category,
  'storyState': 'OFFICIAL',
  'entities': [
    {'type': 'team', 'id': 'fb_team_one', 'name': 'Club Uno'},
  ],
};

void main() {
  test('v1 empty feed remains compatible', () {
    final v1 = <String, dynamic>{'schemaVersion': 1, 'news': []};
    expect(adaptNewsFeed(v1), v1);
  });

  test('v2 stories become one article per canonical cluster', () {
    final result = adaptNewsFeed({
      'schemaVersion': 2,
      'updatedAt': '2026-10-19T12:00:00Z',
      'stories': [
        {
          ..._story('cluster-a', category: 'TRANSFER'),
          'snippet': 'Derechos confirmados',
          'imageUrl': 'https://club.example/protected.jpg',
          'attribution': {'publisher': 'Club Uno', 'provider': 'Currents API'},
        },
        _story('cluster-a'),
        _story('cluster-b'),
      ],
    });
    expect(result['schemaVersion'], 1);
    final news = result['news'] as List;
    expect(news, hasLength(2));
    expect(news.first['description'], isNull);
    expect(news.first['imageUrl'], isNull);
    expect(news.first['provider'], 'Currents API');
    expect(news.first['featured'], isNull);
    expect(news.first['author'], isNull);
    expect(news.first['subjects'], [
      {'type': 'team', 'id': 'fb_team_one'},
    ]);
    expect(
      newsForSection(news.cast<Map<String, dynamic>>(), NewsSection.transfers),
      hasLength(1),
    );
  });

  test('missing optional rights metadata stays absent', () {
    final result = adaptNewsFeed({
      'schemaVersion': 2,
      'updatedAt': '2026-10-19T12:00:00Z',
      'stories': [_story('cluster-a')],
    });
    final article = (result['news'] as List).single as Map;
    expect(article.containsKey('description'), isFalse);
    expect(article.containsKey('imageUrl'), isFalse);
    expect(article.containsKey('provider'), isFalse);
  });

  test('unsupported or malformed feed fails without fake success', () {
    expect(
      () => adaptNewsFeed({'schemaVersion': 1, 'news': 'invalid'}),
      throwsFormatException,
    );
    expect(
      () => adaptNewsFeed({'schemaVersion': 3, 'stories': []}),
      throwsFormatException,
    );
    expect(
      () => adaptNewsFeed({'schemaVersion': 2, 'stories': []}),
      throwsFormatException,
    );
  });

  test('v1 protected media is removed without mutating the response', () {
    final article = <String, dynamic>{
      'id': 'one',
      'title': 'Comunicado',
      'url': 'https://club.example/one',
      'sourceName': 'Club',
      'description': 'Protected excerpt',
      'snippet': 'Protected excerpt',
      'imageUrl': 'https://club.example/protected.jpg',
    };
    final result = adaptNewsFeed({'schemaVersion': 1, 'news': [article]});
    final safe = (result['news'] as List).single as Map;
    expect(safe['title'], article['title']);
    expect(safe['url'], article['url']);
    for (final key in ['description', 'snippet', 'imageUrl']) {
      expect(safe.containsKey(key), isFalse);
      expect(article.containsKey(key), isTrue);
    }
  });
}

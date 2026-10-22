// Runs without Flutter's socket-based test runner. No network or database.
import '../../apps/mobile/lib/features/news/news_feed_adapter.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void main() {
  final article = <String, dynamic>{
    'id': 'one',
    'title': 'Official statement',
    'url': 'https://club.example/one',
    'sourceName': 'Club',
    'description': 'Protected',
    'snippet': 'Protected',
    'imageUrl': 'https://club.example/image.jpg',
  };
  final v1 = adaptNewsFeed({
    'schemaVersion': 1,
    'news': [article],
  });
  final safe = (v1['news'] as List).single as Map;
  check(safe['url'] == article['url'], 'v1 link lost');
  for (final field in ['description', 'snippet', 'imageUrl']) {
    check(!safe.containsKey(field), 'v1 media retained');
    check(article.containsKey(field), 'input mutated');
  }
  final v2 = adaptNewsFeed({
    'schemaVersion': 2,
    'updatedAt': '2026-10-22T12:00:00Z',
    'stories': [
      for (var i = 0; i < 2; i++)
        {
          ...article,
          'clusterId': 'one',
          'publishedAt': '2026-10-22T11:00:00Z',
          'rights': {'version': 1, 'snippet': 'ALLOWED', 'image': 'ALLOWED'},
        },
    ],
  });
  final stories = v2['news'] as List;
  check(stories.length == 1, 'cluster deduplication lost');
  check((stories.single as Map)['title'] == article['title'], 'title lost');
  for (final field in ['description', 'snippet', 'imageUrl']) {
    check(!(stories.single as Map).containsKey(field), 'v2 media retained');
  }
  for (final invalid in [
    {'schemaVersion': 1, 'news': 'invalid'},
    {'schemaVersion': 2, 'stories': []},
    {'schemaVersion': 3},
  ]) {
    var rejected = false;
    try {
      adaptNewsFeed(invalid);
    } on FormatException {
      rejected = true;
    }
    check(rejected, 'invalid feed accepted');
  }
  print(
    'PASS: v1/v2 link-out, input isolation, deduplication, malformed feeds',
  );
}

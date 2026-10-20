import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/features/news/news_feed_adapter.dart';

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
  test('shared backend rights fixture is interpreted without granting revoked media', () {
    final fixture = jsonDecode(
      File('../../packages/contracts/news-rights-v1.fixture.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    final news =
        (adaptNewsFeed(fixture, now: DateTime.utc(2026, 10, 19, 12))['news']
                as List)
            .cast<Map<String, dynamic>>();
    expect(news, hasLength(2));
    expect(news.first['description'], 'Extracto autorizado');
    expect(news.first['imageUrl'], 'https://club.example/image.png');
    expect(news.last.containsKey('description'), isFalse);
    expect(news.last.containsKey('imageUrl'), isFalse);
    expect(news.last['title'], 'Comunicado con permisos revocados');
  });
  test('v1 is link-only without rights metadata', () {
    final v1 = <String, dynamic>{
      'schemaVersion': 1,
      'news': [
        {
          'title': 'Titular',
          'url': 'https://club.example',
          'description': 'Texto protegido',
          'imageUrl': 'https://club.example/x.png',
        },
      ],
    };
    final article = (adaptNewsFeed(v1)['news'] as List).single as Map;
    expect(article['title'], 'Titular');
    expect(article['url'], 'https://club.example');
    expect(article.containsKey('description'), isFalse);
    expect(article.containsKey('imageUrl'), isFalse);
  });

  test('v2 stories become one article per canonical cluster', () {
    final result = adaptNewsFeed({
      'schemaVersion': 2,
      'updatedAt': '2026-10-19T12:00:00Z',
      'stories': [
        {
          ..._story('cluster-a', category: 'TRANSFER'),
          'snippet': 'Derechos confirmados',
          'rights': {
            'version': 1,
            'checkedAt': '2026-10-19T12:00:00Z',
            'expiresAt': '2026-10-19T12:00:30Z',
            'snippet': 'ALLOWED',
            'image': 'REVOKED',
          },
          'attribution': {'publisher': 'Club Uno', 'provider': 'Currents API'},
        },
        _story('cluster-a'),
        _story('cluster-b'),
      ],
    }, now: DateTime.utc(2026, 10, 19, 12));
    expect(result['schemaVersion'], 1);
    final news = result['news'] as List;
    expect(news, hasLength(2));
    expect(news.first['description'], 'Derechos confirmados');
    expect(news.first['provider'], 'Currents API');
    expect(news.first['featured'], isNull);
    expect(news.first['author'], isNull);
    expect(news.first['subjects'], [
      {'type': 'team', 'id': 'fb_team_one'},
    ]);
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

  test('rights revocation and absent or expired attestation strip protected fields', () {
    Map<String, dynamic> feed({
      String? snippetState,
      String? imageState,
      String checkedAt = '2026-10-19T12:00:00Z',
      String expiresAt = '2026-10-19T12:00:30Z',
    }) => {
      'schemaVersion': 2,
      'updatedAt': '2026-10-19T12:00:00Z',
      'stories': [
        {
          ..._story('cluster-a'),
          'snippet': 'Extracto autorizado',
          'imageUrl': 'https://club.example/x.png',
          if (snippetState != null && imageState != null)
            'rights': {
              'version': 1,
              'checkedAt': checkedAt,
              'expiresAt': expiresAt,
              'snippet': snippetState,
              'image': imageState,
            },
        },
      ],
    };
    Map article(Map<String, dynamic> raw) =>
        (adaptNewsFeed(raw, now: DateTime.utc(2026, 10, 19, 12))['news']
                    as List)
                .single
            as Map;
    final allowed = article(
      feed(snippetState: 'ALLOWED', imageState: 'ALLOWED'),
    );
    expect(allowed['description'], 'Extracto autorizado');
    expect(allowed['imageUrl'], 'https://club.example/x.png');
    expect(allowed['snippetRights'], 'ALLOWED');
    expect(allowed['imageRights'], 'ALLOWED');
    for (final result in [
      article(feed(snippetState: 'REVOKED', imageState: 'REVOKED')),
      article(feed()),
      article(
        feed(
          snippetState: 'ALLOWED',
          imageState: 'ALLOWED',
          expiresAt: '2026-10-19T11:59:59Z',
        ),
      ),
    ]) {
      expect(result.containsKey('description'), isFalse);
      expect(result.containsKey('imageUrl'), isFalse);
      expect(result['title'], 'Comunicado cluster-a');
      expect(result['url'], 'https://club.example/cluster-a');
    }
    final split = article(feed(snippetState: 'ALLOWED', imageState: 'REVOKED'));
    expect(split['description'], 'Extracto autorizado');
    expect(split.containsKey('imageUrl'), isFalse);
    expect(split['imageRights'], 'REVOKED');
    expect(article(feed())['snippetRights'], 'ABSENT');
    expect(
      article(
        feed(snippetState: 'UNVERIFIED', imageState: 'ALLOWED'),
      )['snippetRights'],
      'UNVERIFIED',
    );
    expect(
      article(
        feed(
          snippetState: 'ALLOWED',
          imageState: 'ALLOWED',
          expiresAt: '2026-10-19T11:59:59Z',
        ),
      )['snippetRights'],
      'UNVERIFIED',
    );
    expect(
      article(
        feed(
          snippetState: 'ALLOWED',
          imageState: 'ALLOWED',
          checkedAt: '2026-10-19T11:59:30Z',
          expiresAt: '2026-10-19T12:00:00Z',
        ),
      )['snippetRights'],
      'EXPIRED',
    );
  });

  test('unsupported or malformed feed fails without fake success', () {
    expect(
      () => adaptNewsFeed({'schemaVersion': 3, 'stories': []}),
      throwsFormatException,
    );
    expect(
      () => adaptNewsFeed({'schemaVersion': 2, 'stories': []}),
      throwsFormatException,
    );
  });
}

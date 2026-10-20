import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/news_links.dart';
import 'package:futbeat/features/news/news_feed_adapter.dart';
import 'package:futbeat/features/news/news_screen.dart';

void main() {
  final timestamp = DateTime.now().toUtc().toIso8601String();
  Json article(
    String id,
    String title,
    List<Json> subjects, {
    String category = 'GENERAL',
  }) => {
    'id': id,
    'title': title,
    'sourceName': 'Medio sintético',
    'url': 'https://example.invalid/$id',
    'publishedAt': timestamp,
    'subjects': subjects,
    'category': category,
  };

  test(
    'country changes do not remove global or followed stories from loaded feed',
    () {
      final stories = [
        article('global', 'Noticia internacional', []),
        article('club', 'Equipo seguido', [
          {'type': 'team', 'id': 'fb_team_123'},
        ]),
      ];
      expect(
        newsForSection(
          stories,
          NewsSection.forYou,
          follows: {'team:fb_team_123'},
        ),
        hasLength(2),
      );
      expect(
        newsForSection(
          stories,
          NewsSection.teams,
          follows: {'team:fb_team_123'},
        ).single['id'],
        'club',
      );
      expect(newsForSection(stories, NewsSection.latest), hasLength(2));
    },
  );

  test(
    'canonical followed entities filter locally and search adds no request',
    () {
      final stories = [
        article('team', 'Alajuelense', [
          {'type': 'team', 'id': 'fb_team_123'},
        ]),
        article('player', 'Jugador', [
          {'type': 'player', 'id': 'fb_player_123'},
        ]),
        article('league', 'Liga', [
          {'type': 'competition', 'id': 'fb_comp_123'},
        ]),
        article('transfer', 'Fichaje', [], category: 'TRANSFER'),
      ];
      final follows = {
        'team:fb_team_123',
        'player:fb_player_123',
        'competition:fb_comp_123',
      };
      expect(
        newsForSection(
          stories,
          NewsSection.players,
          follows: follows,
        ).single['id'],
        'player',
      );
      expect(
        newsForSection(
          stories,
          NewsSection.competitions,
          follows: follows,
        ).single['id'],
        'league',
      );
      expect(
        newsForSection(stories, NewsSection.transfers).single['id'],
        'transfer',
      );
      expect(
        newsForSection(stories, NewsSection.forYou, query: 'ausente'),
        isEmpty,
      );
    },
  );

  test('adapter preserves distinct country, publisher and language without rights inference', () {
    final adapted = adaptNewsFeed({
      'schemaVersion': 2,
      'updatedAt': timestamp,
      'stories': [
        {
          'clusterId': 'story:1',
          'title': 'Hecho sintético',
          'url': 'https://example.invalid/1',
          'sourceName': 'Medio',
          'sourceCountryCode': 'CR',
          'language': 'es',
          'storyCountryNames': ['España'],
          'inSelectedCountry': false,
          'publishedAt': timestamp,
          'entities': [
            {'type': 'team', 'id': 'fb_team_123', 'name': 'Club sintético'},
          ],
          'snippet': 'No autorizado',
          'imageUrl': 'https://example.invalid/image',
        },
      ],
    });
    final news = (adapted['news'] as List).single as Json;
    expect(news['sourceCountryCode'], 'CR');
    expect(news['storyCountryNames'], ['España']);
    expect(news['associatedEntities'], ['Club sintético']);
    expect(news.containsKey('description'), isFalse);
    expect(news.containsKey('imageUrl'), isFalse);
  });

  test('article links require safe public HTTPS URL', () {
    expect(safeNewsUri('https://example.invalid/article'), isNotNull);
    for (final value in [
      'http://example.invalid',
      'javascript:alert(1)',
      'https://user:pass@example.invalid',
      'https://localhost/a',
      'https://127.0.0.1/a',
    ]) {
      expect(safeNewsUri(value), isNull);
    }
  });

  testWidgets('internal detail only shows metadata, never protected snippet', (
    tester,
  ) async {
    final story = article('story', 'Titular', []);
    story['description'] = 'Extracto protegido';
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showNewsDetails(context, story),
              child: const Text('Abrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
    expect(find.text('Titular'), findsOneWidget);
    expect(find.textContaining('Medio sintético'), findsOneWidget);
    expect(find.text('Extracto protegido'), findsNothing);
    expect(find.text('Leer noticia original'), findsOneWidget);
  });
}

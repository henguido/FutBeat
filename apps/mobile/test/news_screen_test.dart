import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/news/news_screen.dart';

// Noticias shows real stored articles and roster changes from /v1/news;
// never a placeholder or an invented article. Synthetic data only.

Map<String, dynamic> _feed({
  List<Map<String, dynamic>> news = const [],
  List<Map<String, dynamic>> transfers = const [],
}) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-10-05T00:00:00Z',
  'coverage': {'partial': false},
  'freshness': {'stale': false},
  'competitions': <dynamic>[],
  'teams': <dynamic>[],
  'players': <dynamic>[],
  'matches': <dynamic>[],
  'standings': <dynamic>[],
  'news': news,
  'transfers': transfers,
};

Map<String, dynamic> _article(String id, {String? image}) => {
  'id': id,
  'title': 'Titular $id',
  'url': 'https://news.test/$id',
  'sourceName': 'Fuente $id',
  'publishedAt': '2026-10-04T12:00:00Z',
  'imageUrl': ?image,
};

Future<List<RequestOptions>> _pump(
  WidgetTester tester,
  FutureOr<Response<dynamic>> Function(RequestOptions) answer, {
  Set<String> follows = const {},
}) async {
  final requests = <RequestOptions>[];
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (o, h) async {
        requests.add(o);
        try {
          h.resolve(await answer(o));
        } on DioException catch (e) {
          h.reject(e);
        }
      },
    ),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        repositoryProvider.overrideWithValue(ApiRepository(dio)),
        followsProvider.overrideWith((ref) => Stream.value(follows)),
        preferenceProvider.overrideWith(
          (ref) => Stream.value(
            const CountryPreference(
              detectedCountry: 'CR',
              selectedCountry: null,
              bootstrapDismissed: true,
            ),
          ),
        ),
      ],
      child: const MaterialApp(home: NewsScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return requests;
}

void main() {
  test('only sections supported by the current feed contract are offered', () {
    expect(NewsSection.values.map((section) => section.label), [
      'Para ti',
      'Últimas',
      'Equipos seguidos',
      'Jugadores seguidos',
      'Competiciones',
      'Fichajes',
    ]);
  });

  test(
    'local search and latest ordering cover only the 40 loaded articles',
    () {
      final articles = List<Json>.generate(
        40,
        (index) => {
          ..._article('article-$index'),
          'publishedAt': DateTime.utc(
            2026,
            10,
            4,
          ).add(Duration(minutes: index)).toIso8601String(),
        },
      );
      expect(
        newsForSection(
          articles,
          NewsSection.forYou,
          query: 'article-39',
        ).map((article) => article['id']),
        ['article-39'],
      );
      expect(
        newsForSection(articles, NewsSection.forYou, query: 'article-40'),
        isEmpty,
      );
      final latest = newsForSection(articles, NewsSection.latest);
      expect(latest, hasLength(40));
      expect(latest.first['id'], 'article-39');
      expect(latest.last['id'], 'article-0');
    },
  );

  test('followed entity filters require explicit typed canonical subjects', () {
    final articles = <Json>[
      {
        ..._article('club'),
        'subjects': [
          {'type': 'team', 'id': 'fb_team_a'},
        ],
      },
      {
        ..._article('player'),
        'subjects': [
          {'type': 'player', 'id': 'fb_player_b'},
        ],
      },
      {..._article('untagged'), 'subjects': const []},
    ];
    final follows = {'team:fb_team_a', 'player:fb_player_b'};
    expect(
      newsForSection(
        articles,
        NewsSection.teams,
        follows: follows,
      ).map((article) => article['id']),
      ['club'],
    );
    expect(
      newsForSection(
        articles,
        NewsSection.players,
        follows: follows,
      ).map((article) => article['id']),
      ['player'],
    );
    expect(newsForSection(articles, NewsSection.forYou), hasLength(3));
  });

  test('followed player and competition filters do not infer from names', () {
    final articles = <Json>[
      {
        ..._article('player-followed'),
        'title': 'Jugador de selección y club',
        'subjects': [
          {'type': 'player', 'id': 'fb_player_followed'},
          {'type': 'team', 'id': 'fb_team_other'},
        ],
      },
      {
        ..._article('competition-followed'),
        'subjects': [
          {'type': 'competition', 'id': 'fb_comp_followed'},
        ],
      },
      {
        ..._article('name-only'),
        'title': 'fb_player_followed y fb_comp_followed',
      },
      {
        ..._article('wrong-kind'),
        'subjects': [
          {'type': 'team', 'id': 'fb_player_followed'},
        ],
      },
    ];
    final follows = {
      'player:fb_player_followed',
      'competition:fb_comp_followed',
    };

    expect(
      newsForSection(
        articles,
        NewsSection.players,
        follows: follows,
      ).map((article) => article['id']),
      ['player-followed'],
    );
    expect(
      newsForSection(
        articles,
        NewsSection.competitions,
        follows: follows,
      ).map((article) => article['id']),
      ['competition-followed'],
    );
    expect(
      newsForSection(articles, NewsSection.players, follows: const {}),
      isEmpty,
    );
  });

  test('invalid article provenance is excluded without inferring metadata', () {
    final valid = _article('valid');
    expect(
      newsForSection([
        valid,
        {...valid, 'id': 'missing-source', 'sourceName': ''},
        {...valid, 'id': 'unsafe-url', 'url': 'http://news.test/unsafe'},
        {...valid, 'id': 'undated', 'publishedAt': 'unknown'},
      ], NewsSection.forYou).map((article) => article['id']),
      ['valid'],
    );
  });

  testWidgets('optional metadata is explicit and featured is shown once', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              NewsFeedContent(
                articles: [
                  {..._article('featured'), 'featured': true, 'author': 'Ana'},
                  {..._article('ordinary'), 'featured': 'true', 'author': 42},
                  _article('without-metadata'),
                ],
                transfers: const [],
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Destacados'), findsOneWidget);
    expect(find.text('Titular featured'), findsOneWidget);
    expect(find.text('Fuente featured · Ana · 4/10/2026'), findsOneWidget);
    expect(find.textContaining('42'), findsNothing);
    expect(find.text('Titular ordinary'), findsOneWidget);
    expect(find.text('Titular without-metadata'), findsOneWidget);
    expect(find.text('Mi país'), findsNothing);
    expect(find.text('Globales'), findsNothing);
    expect(
      find.text('Búsqueda local; el feed carga hasta 40 artículos.'),
      findsOneWidget,
    );
  });

  testWidgets('articles and roster changes, followed subjects sent', (
    tester,
  ) async {
    final requests = await _pump(
      tester,
      (o) => Response(
        requestOptions: o,
        data: _feed(
          news: [_article('a1'), _article('a2')],
          transfers: [
            {
              'id': 1,
              'playerName': 'Jugador Uno',
              'fromTeamName': 'Club A',
              'toTeamName': 'Club B',
              'detectedAt': '2026-10-04T10:00:00Z',
              'source': 'GOAL API · plantilla de equipo',
            },
          ],
        ),
      ),
      follows: {'team:fb_team_b', 'player:fb_player_x', 'team:fb_team_a'},
    );
    expect(requests.single.path, '/v1/news');
    expect(
      requests.single.queryParameters['subjects'],
      'player:fb_player_x,team:fb_team_a,team:fb_team_b',
    );
    expect(requests.single.queryParameters['country'], 'CR');
    expect(find.text('Titular a1'), findsOneWidget);
    expect(find.text('Titular a2'), findsOneWidget);
    expect(find.text('Transferencias'), findsOneWidget);
    expect(find.textContaining('Próximo incremento'), findsNothing);
  });

  testWidgets('local search and filters do not request or duplicate news', (
    tester,
  ) async {
    final requests = await _pump(
      tester,
      (o) => Response(
        requestOptions: o,
        data: _feed(
          news: [
            {
              ..._article('club'),
              'subjects': [
                {'type': 'team', 'id': 'fb_team_a'},
              ],
            },
            _article('ordinary'),
          ],
        ),
      ),
      follows: {'team:fb_team_a'},
    );
    expect(requests, hasLength(1));
    await tester.enterText(find.byKey(const ValueKey('news-search')), 'club');
    await tester.pumpAndSettle();
    expect(find.text('Titular club'), findsOneWidget);
    expect(find.text('Titular ordinary'), findsNothing);
    await tester.tap(find.text('Equipos seguidos'));
    await tester.pumpAndSettle();
    expect(find.text('Titular club'), findsOneWidget);
    expect(requests, hasLength(1));
  });

  testWidgets(
    'empty filters explain missing follows and search can be cleared',
    (tester) async {
      final requests = await _pump(
        tester,
        (o) => Response(
          requestOptions: o,
          data: _feed(news: [_article('available')]),
        ),
      );
      await tester.tap(find.text('Equipos seguidos'));
      await tester.pumpAndSettle();
      expect(find.text('Aún no sigues equipos'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('news-search')),
        'sin-coincidencias',
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Sin resultados para «sin-coincidencias»'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('news-search-clear')));
      await tester.pumpAndSettle();
      expect(find.text('Aún no sigues equipos'), findsOneWidget);
      expect(requests, hasLength(1));
    },
  );

  testWidgets(
    'followed player and competition chips use the loaded feed only',
    (tester) async {
      final requests = await _pump(
        tester,
        (o) => Response(
          requestOptions: o,
          data: _feed(
            news: [
              {
                ..._article('player'),
                'subjects': [
                  {'type': 'player', 'id': 'fb_player_a'},
                ],
              },
              {
                ..._article('competition'),
                'subjects': [
                  {'type': 'competition', 'id': 'fb_comp_a'},
                ],
              },
              _article('unrelated'),
            ],
          ),
        ),
        follows: {'player:fb_player_a', 'competition:fb_comp_a'},
      );
      expect(requests, hasLength(1));
      expect(
        requests.single.queryParameters['subjects'],
        'competition:fb_comp_a,player:fb_player_a',
      );

      await tester.ensureVisible(find.text('Jugadores seguidos'));
      await tester.tap(find.text('Jugadores seguidos'));
      await tester.pumpAndSettle();
      expect(find.text('Titular player'), findsOneWidget);
      expect(find.text('Titular competition'), findsNothing);
      expect(find.text('Titular unrelated'), findsNothing);

      await tester.ensureVisible(find.text('Competiciones'));
      await tester.tap(find.text('Competiciones'));
      await tester.pumpAndSettle();
      expect(find.text('Titular competition'), findsOneWidget);
      expect(find.text('Titular player'), findsNothing);
      expect(requests, hasLength(1));
    },
  );

  testWidgets('no articles: honest empty state, nothing invented', (
    tester,
  ) async {
    await _pump(tester, (o) => Response(requestOptions: o, data: _feed()));
    expect(find.text('Sin noticias disponibles'), findsOneWidget);
    expect(find.text('Noticias'), findsOneWidget, reason: 'only the app bar');
  });

  testWidgets('error then retry loads the feed', (tester) async {
    var fail = true;
    await _pump(tester, (o) {
      if (fail) {
        throw DioException(requestOptions: o, message: 'offline');
      }
      return Response(
        requestOptions: o,
        data: _feed(news: [_article('r1')]),
      );
    });
    expect(find.text('No pudimos cargar las noticias'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Reintentar'));
    await tester.pumpAndSettle();
    expect(find.text('Titular r1'), findsOneWidget);
  });

  testWidgets('an https image is shown; a failing one takes no space', (
    tester,
  ) async {
    await _pump(
      tester,
      (o) => Response(
        requestOptions: o,
        data: _feed(
          news: [
            _article('i1', image: 'https://img.test/x.jpg'),
            _article('i2', image: 'http://img.test/y.jpg'),
          ],
        ),
      ),
    );
    // Test HTTP returns 400 for every image: the error builder hides it
    // and leaves no empty 16:9 box behind.
    expect(find.byKey(const ValueKey('news-image')), findsOneWidget);
    expect(find.byType(AspectRatio), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a server without /v1/news (404) reads as no news, not an error',
    (tester) async {
      await _pump(
        tester,
        (o) => throw DioException(
          requestOptions: o,
          response: Response(requestOptions: o, statusCode: 404),
          type: DioExceptionType.badResponse,
        ),
      );
      expect(find.text('Sin noticias disponibles'), findsOneWidget);
      expect(find.text('No pudimos cargar las noticias'), findsNothing);
    },
  );
}

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/news/news_screen.dart';

Snapshot feed({List<Map<String, dynamic>> news = const []}) => Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': DateTime.now().toUtc().toIso8601String(),
  'coverage': {'partial': false},
  'freshness': {'stale': false},
  'teams': <dynamic>[],
  'players': <dynamic>[],
  'competitions': <dynamic>[],
  'matches': <dynamic>[],
  'standings': <dynamic>[],
  'news': news,
  'transfers': <dynamic>[],
});

void main() {
  testWidgets('Noticias v1 shows a truthful empty state', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [newsFeedProvider.overrideWith((ref) async => feed())],
        child: const MaterialApp(home: NewsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sin noticias disponibles'), findsOneWidget);
  });

  testWidgets('Noticias v1 shows errors without a false success', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          newsFeedProvider.overrideWith(
            (ref) async => throw StateError('offline'),
          ),
        ],
        child: const MaterialApp(home: NewsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No pudimos cargar las noticias'), findsOneWidget);
    expect(find.text('Reintentar'), findsOneWidget);
  });

  testWidgets('Noticias v1 displays source-attributed stored headlines', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          newsFeedProvider.overrideWith(
            (ref) async => feed(
              news: [
                {
                  'id': 'fixture-news',
                  'title': 'Titular de prueba',
                  'sourceName': 'Fuente sintética',
                  'url': 'https://example.invalid/article',
                  'publishedAt': DateTime.now().toUtc().toIso8601String(),
                },
              ],
            ),
          ),
        ],
        child: const MaterialApp(home: NewsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Titular de prueba'), findsOneWidget);
    expect(find.textContaining('Fuente sintética'), findsOneWidget);
    expect(find.text('Sin noticias disponibles'), findsNothing);
  });
}

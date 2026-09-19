import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/shared/widgets.dart';

void main() {
  test('snapshot accepts optional news and transfer arrays', () {
    final snapshot = Snapshot({
      'schemaVersion': 1,
      'demo': false,
      'updatedAt': '2026-09-19T04:00:00Z',
      'freshness': {'stale': false},
      'teams': <dynamic>[],
      'players': <dynamic>[],
      'competitions': <dynamic>[],
      'matches': <dynamic>[],
      'standings': <dynamic>[],
      'news': [
        {
          'id': 'newsdata:a1',
          'title': 'Titular',
          'url': 'https://example.com/a1',
          'sourceName': 'Medio',
          'publishedAt': '2026-09-19T02:00:00Z',
        },
      ],
      'transfers': [
        {
          'id': 1,
          'playerName': 'Jugador',
          'fromTeamName': 'Anterior',
          'toTeamName': 'Nuevo',
          'detectedAt': '2026-09-19T03:00:00Z',
          'status': 'ROSTER_CHANGE',
          'source': 'GOAL API · plantilla de equipo',
        },
      ],
    });

    expect(snapshot.news, hasLength(1));
    expect(snapshot.transfers, hasLength(1));
    expect(snapshot.news.first['sourceName'], 'Medio');
    expect(snapshot.transfers.first['status'], 'ROSTER_CHANGE');
  });

  testWidgets('news card shows source and copies only an external link', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NewsArticleCard({
            'id': 'newsdata:a1',
            'title': 'Saprissa prepara su próximo partido',
            'description': 'Resumen corto.',
            'url': 'https://example.com/article',
            'sourceName': 'Medio Ejemplo',
            'publishedAt': '2026-09-19T02:00:00Z',
          }),
        ),
      ),
    );

    expect(find.text('Saprissa prepara su próximo partido'), findsOneWidget);
    expect(find.textContaining('Medio Ejemplo'), findsOneWidget);
    expect(find.text('Copiar enlace'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('transfer card clearly labels a roster-detected move', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TransferEventCard({
            'id': 1,
            'playerName': 'Jugador Uno',
            'fromTeamName': 'Club A',
            'toTeamName': 'Club B',
            'detectedAt': '2026-09-19T03:00:00Z',
            'status': 'ROSTER_CHANGE',
            'source': 'GOAL API · plantilla de equipo',
          }),
        ),
      ),
    );

    expect(find.text('Jugador Uno'), findsOneWidget);
    expect(find.textContaining('Club A → Club B'), findsOneWidget);
    expect(
      find.textContaining('Cambio detectado en plantilla'),
      findsOneWidget,
    );
    expect(find.textContaining('GOAL API'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

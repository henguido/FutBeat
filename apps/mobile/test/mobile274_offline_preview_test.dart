import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/qa_development.dart';
import 'package:futbeat/features/news/news_screen.dart';
import 'package:futbeat/shared/widgets.dart';

void main() {
  testWidgets('offline Preview cannot delegate news navigation', (
    tester,
  ) async {
    final article = <String, dynamic>{
      'title': 'Comunicado',
      'url': 'https://example.invalid/articulo',
    };
    var opens = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                NewsArticleCard(
                  article,
                  openLink: (_) async {
                    opens++;
                    return true;
                  },
                ),
                TextButton(
                  onPressed: () => showNewsDetails(context, article),
                  child: const Text('Detalle'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Leer noticia'));
    await tester.pumpAndSettle();
    expect(opens, 0);
    await tester.tap(find.text('Detalle'));
    await tester.pumpAndSettle();
    final open = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Leer noticia original'),
    );
    expect(open.onPressed, isNull);
  }, skip: !offlinePreview);
}

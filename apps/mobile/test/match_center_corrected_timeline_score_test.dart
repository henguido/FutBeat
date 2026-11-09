import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/features/matches/timeline_presentation.dart';

void main() {
  test('a corrected structured score hides the stale detail score only', () {
    expect(
      timelineMetadata(
        event: {
          'score': {'home': 1, 'away': 0},
          'detail': '2 - 0 · Revisión VAR',
        },
        typeLabel: 'Gol',
        title: 'Jugador',
        score: '1–0',
      ),
      ['Gol', 'Revisión VAR'],
    );
  });
}

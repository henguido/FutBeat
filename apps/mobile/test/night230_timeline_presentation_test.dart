import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/features/matches/timeline_presentation.dart';

void main() {
  test('explicit null score correction is not revived by old free text', () {
    expect(
      timelineMetadata(
        event: {
          'score': null,
          'playerName': 'J. Garner',
          'detail': 'J. Garner · 1 - 0 · Revisión pendiente',
        },
        typeLabel: 'Gol',
        title: 'James Garner',
        playerName: 'James Garner',
      ),
      ['Gol', 'Revisión pendiente'],
    );
  });

  test('real saved goal does not repeat provider scorer, assist or score', () {
    final fixture = jsonDecode(
      File('test/fixtures/everton_newcastle_qa225_timeline.json')
          .readAsStringSync(),
    ) as Json;
    final row = Map<String, dynamic>.from(
      (fixture['detail']['incidents'] as List).first,
    );
    expect(
      timelineMetadata(
        event: row,
        typeLabel: 'Gol',
        title: 'James Garner',
        playerName: 'James Garner',
        assistName: 'Hayden Hackney',
        score: '1–0',
      ),
      ['Gol'],
    );
    expect(row['detail'], 'J. Garner · Asistencia: H. Hackney · 1 - 0');
  });
  test('unrecognized correction and VAR explanations remain visible', () {
    expect(
      timelineMetadata(
        event: {'detail': 'Gol anulado · Revisión por fuera de juego'},
        typeLabel: 'VAR',
        title: 'Jugador',
        playerName: 'Jugador',
      ),
      ['VAR', 'Gol anulado', 'Revisión por fuera de juego'],
    );
  });
  test('different score and unpaired names are not hidden', () {
    expect(
      timelineMetadata(
        event: {'detail': 'Otro jugador · 2 - 1 · Asistencia: Otra persona'},
        typeLabel: 'Gol',
        title: 'Jugador',
        playerName: 'Jugador',
        assistName: 'Asistente',
        score: '1–0',
      ),
      ['Gol', 'Otro jugador', '2 - 1', 'Asistencia: Otra persona'],
    );
  });
  test('substitution fallback and unknown annotations are retained once', () {
    expect(
      timelineMetadata(
        event: {'detail': 'Salida | Entrada · Lesión · Lesión'},
        typeLabel: 'Sustitución',
        title: 'Salida | Entrada',
      ),
      ['Sustitución', 'Lesión'],
    );
  });
}

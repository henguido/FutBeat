import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:futbeat/core/models.dart';

FootballMatch _match({
  required String status,
  DateTime? startTime,
  int? minute,
  DateTime? liveChangedAt,
}) {
  return FootballMatch({
    'id': 'fb_match_copy_guard',
    'competitionId': 'fb_comp_copy_guard',
    'homeTeamId': 'fb_team_home_copy_guard',
    'awayTeamId': 'fb_team_away_copy_guard',
    'startTime': (startTime ?? DateTime.now().toUtc()).toIso8601String(),
    'status': status,
    'score': status == 'LIVE' ? {'home': 0, 'away': 0} : null,
    'minute': minute,
    if (liveChangedAt != null) 'liveChangedAt': liveChangedAt.toIso8601String(),
    'events': <dynamic>[],
    'statistics': <dynamic>[],
    'provenance': {
      'source': 'GOAL API',
      'receivedAt': DateTime.now().toUtc().toIso8601String(),
    },
  });
}

void main() {
  test('overdue scheduled matches never expose technical pending copy', () {
    final match = _match(
      status: 'SCHEDULED',
      startTime: DateTime.now().toUtc().subtract(const Duration(hours: 2)),
    );

    expect(match.isAwaitingUpdate, isTrue);
    expect(match.isScheduled, isTrue);
    expect(match.isUpcoming, isFalse);
    expect(match.statusLabel, 'Programado');
  });

  test(
    'stale live transport remains a football status, not a system warning',
    () {
      final match = _match(
        status: 'LIVE',
        minute: 29,
        liveChangedAt: DateTime.now().toUtc().subtract(
          const Duration(hours: 1),
        ),
      );

      expect(match.statusLabel, "29′ · En vivo");
      expect(match.statusLabel.toLowerCase(), isNot(contains('atrasad')));
    },
  );

  test('pending verification is presented as a normal final state', () {
    final match = _match(status: 'FINISHED_PENDING_VERIFICATION');
    expect(match.statusLabel, 'Finalizado');
  });

  test('Match Center contains no synthetic provider-status legends', () {
    final source = File('lib/features/matches/match_screen.dart')
        .readAsStringSync();

    for (final forbidden in [
      'Solicitamos alineaciones',
      'Actualizar detalles',
      'Ya solicitamos el detalle',
      'Mostraremos únicamente',
      'La fuente todavía no publicó',
      'Los eventos aparecerán cuando la fuente',
      'Fuente:',
      'Actualización:',
    ]) {
      expect(source, isNot(contains(forbidden)), reason: forbidden);
    }
  });

  test('MatchDetail.lineupEnrichmentPending reads coverage.lineupEnrichmentPending', () {
    final pending = MatchDetail({...MatchDetail.empty('fb_match').json,
      'coverage': {'lineupEnrichmentPending': true}});
    expect(pending.lineupEnrichmentPending, isTrue);

    final settled = MatchDetail(MatchDetail.empty('fb_match').json);
    expect(settled.lineupEnrichmentPending, isFalse);
  });
}

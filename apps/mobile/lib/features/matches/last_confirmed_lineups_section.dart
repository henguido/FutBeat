import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/device_time.dart';
import '../../core/last_confirmed_lineups.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';

/// Historical rows never enter the current match's detail, events or player sheet.
class MatchLastLineupsSection extends ConsumerWidget {
  const MatchLastLineupsSection({
    required this.data,
    required this.match,
    required this.detail,
    required this.currentLineups,
    this.preview,
    super.key,
  });
  final Snapshot data;
  final FootballMatch match;
  final MatchDetail detail;
  final Widget currentLineups;
  final MatchPreview? preview;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (hasCurrentLineup(detail) ||
        !lastLineupsEligible(match) ||
        !ref.watch(lastConfirmedLineupsEnabledProvider)) {
      return currentLineups;
    }
    final history = ref.watch(matchLastConfirmedLineupsProvider(match.id));
    // Server eligibility overrides an older scheduled calendar snapshot.
    if (history.asData?.value?.json['eligible'] == false) {
      return currentLineups;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text(
            'Última alineación confirmada',
            key: ValueKey('last-lineups-title'),
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
        ),
        const Text(
          'Referencia histórica. No es una predicción ni la alineación de este partido.',
          style: TextStyle(color: muted),
        ),
        const SizedBox(height: 12),
        history.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Consultando la alineación anterior…',
              key: ValueKey('last-lineups-loading'),
            ),
          ),
          error: (_, _) => const _HistoryEmpty(
            'El historial no está disponible en este momento.',
          ),
          data: (value) {
            final sides = value == null
                ? <HistoricalLineupSide>[]
                : [
                    for (final side in ['home', 'away'])
                      ?value.side(side, match, data),
                  ];
            if (sides.isEmpty) {
              return const _HistoryEmpty(
                'Todavía no hay una alineación anterior confirmada disponible.',
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (value!.offline)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Histórico guardado sin conexión',
                      key: ValueKey('last-lineups-offline'),
                      style: TextStyle(color: muted),
                    ),
                  ),
                for (final side in ['home', 'away'])
                  if (value.side(side, match, data) case final previous?)
                    _HistoricalSideCard(previous, data, preview, value)
                  else
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'Sin alineación anterior confirmada para ${data.team(side == 'home' ? match.homeId : match.awayId)?.displayName ?? (side == 'home' ? 'el equipo local' : 'el equipo visitante')}.',
                        style: const TextStyle(color: muted),
                      ),
                    ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _HistoryEmpty extends StatelessWidget {
  const _HistoryEmpty(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey('last-lineups-empty'),
    padding: const EdgeInsets.all(16),
    child: Text(message, style: const TextStyle(color: muted)),
  );
}

class _HistoricalSideCard extends StatelessWidget {
  const _HistoricalSideCard(this.side, this.data, this.preview, this.history);
  final HistoricalLineupSide side;
  final Snapshot data;
  final MatchPreview? preview;
  final LastConfirmedLineups history;
  @override
  Widget build(BuildContext context) {
    DeviceTimeScope.watch(context);
    final team = data.team(side.teamId);
    final opponent =
        history.entity('teams', side.opponentId) ??
        data.team(side.opponentId) ??
        preview?.team(side.opponentId);
    final competition =
        history.entity('competitions', side.competitionId)?.displayName ??
        data.competition(side.competitionId)?.displayName ??
        preview?.competitionName(side.competitionId);
    final date = MaterialLocalizations.of(context)
        .formatMediumDate(side.kickoff.toLocal());
    Widget player(Json row, int index) {
      final id = row['id'] as String?;
      final entity = id == null ? null : data.player(id);
      return ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        key: ValueKey(
          'last-lineup-player-${side.teamId}-${row['playerKey'] ?? row['id'] ?? index}',
        ),
        leading: entity == null ? null : EntityAvatar(entity, size: 32),
        title: Text(
          row['name'] as String,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: row['number'] == null ? null : Text('#${row['number']}'),
        trailing: id == null ? null : const Icon(Icons.chevron_right, size: 18),
        onTap: id == null ? null : () => context.push('/player/$id'),
      );
    }

    return Card(
      key: ValueKey('last-lineups-team-${side.teamId}'),
      margin: const EdgeInsets.only(bottom: 14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: muted),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    "Última alineación confirmada · ${team?.displayName ?? 'Equipo'}",
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const Chip(label: Text('Histórico')),
              ],
            ),
            Text(
              '$date · ${localTime(context, side.kickoff)}',
              key: ValueKey('last-lineups-date-${side.teamId}'),
              style: const TextStyle(color: muted),
            ),
            Text(
              opponent == null
                  ? 'Rival no disponible'
                  : 'Contra ${opponent.displayName}',
            ),
            Text(
              competition ?? 'Competición no disponible',
              style: const TextStyle(color: muted),
            ),
            if (side.formation != null)
              Text('Formación confirmada: ${side.formation}'),
            const SizedBox(height: 12),
            Text(
              'Titulares (${side.starters.length})',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            for (final (index, row) in side.starters.indexed)
              player(row, index),
            const SizedBox(height: 10),
            Text(
              side.bench.isEmpty
                  ? 'Suplentes no disponibles'
                  : 'Suplentes (${side.bench.length})',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            for (final (index, row) in side.bench.indexed)
              player(row, side.starters.length + index),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: ValueKey('last-lineups-source-${side.teamId}'),
                onPressed: () => context.push('/match/${side.matchId}'),
                icon: const Icon(Icons.history),
                label: const Text('Ver partido anterior'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

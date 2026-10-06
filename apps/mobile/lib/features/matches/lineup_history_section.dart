import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import 'lineup_history.dart';

typedef LineupHistoryRequest = ({String matchId, String teamId});

/// Local seam for a future repository adapter. It is deliberately empty in
/// production V1: no request, fixture or inference is made by opening Previa.
final lineupHistoryProvider =
    Provider.family<List<LineupHistoryEntry>, LineupHistoryRequest>(
      (ref, request) => const [],
    );

class LineupHistorySection extends StatefulWidget {
  const LineupHistorySection({
    required this.teamName,
    required this.entries,
    this.initialCount = 3,
    super.key,
  });

  final String teamName;
  final List<LineupHistoryEntry> entries;
  final int initialCount;

  @override
  State<LineupHistorySection> createState() => _LineupHistorySectionState();
}

class _LineupHistorySectionState extends State<LineupHistorySection> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    if (widget.entries.isEmpty) return const SizedBox.shrink();
    final entries = [...widget.entries]
      ..sort((a, b) => b.kickoff.compareTo(a.kickoff));
    final summary = LineupHistorySummarizer.summarize(entries);
    final visible = _showAll
        ? entries
        : entries.take(widget.initialCount).toList();
    return Column(
      key: ValueKey('lineup-history-${widget.teamName}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 14, 2, 8),
          child: Text(
            'Historial de alineaciones · ${widget.teamName}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
        ),
        if (summary.mostUsedFormation != null ||
            summary.playerFrequencies.isNotEmpty)
          _Trends(summary),
        if (summary.mostUsedFormation != null ||
            summary.playerFrequencies.isNotEmpty)
          const SizedBox(height: 8),
        for (final entry in visible) ...[
          _HistoryEntry(entry),
          const SizedBox(height: 8),
        ],
        if (entries.length > widget.initialCount)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const ValueKey('lineup-history-more'),
              onPressed: () => setState(() => _showAll = !_showAll),
              child: Text(_showAll ? 'Ver menos' : 'Ver más'),
            ),
          ),
      ],
    );
  }
}

class _Trends extends StatelessWidget {
  const _Trends(this.summary);

  final LineupHistorySummary summary;

  @override
  Widget build(BuildContext context) {
    final frequent = summary.playerFrequencies.where((item) => item.starts > 0);
    return Card(
      key: const ValueKey('lineup-history-trends'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Tendencias recientes',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            if (summary.mostUsedFormation != null) ...[
              const SizedBox(height: 6),
              Text(
                'Formación más usada recientemente: ${summary.mostUsedFormation}',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
            ],
            for (final item in frequent.take(3))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${item.player.name}: titular en ${item.starts} de los últimos ${item.consideredMatches}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HistoryEntry extends StatelessWidget {
  const _HistoryEntry(this.entry);

  final LineupHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final date = MaterialLocalizations.of(context)
        .formatShortDate(entry.kickoff);
    return Card(
      key: ValueKey('lineup-history-${entry.matchId}'),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        title: Row(
          children: [
            Expanded(
              child: Text(
                entry.opponent.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            if (entry.result != null && entry.result!.trim().isNotEmpty)
              Text(
                entry.result!,
                style: const TextStyle(
                  color: lime,
                  fontWeight: FontWeight.w900,
                ),
              ),
          ],
        ),
        subtitle: Text(
          [
            date,
            entry.competition,
            if (entry.formation?.trim().isNotEmpty == true) entry.formation!,
          ].join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: muted, fontSize: 12),
        ),
        trailing: _StatusAndExpand(status: entry.lineupStatus),
        children: [_EntryDetails(entry)],
      ),
    );
  }
}

class _StatusAndExpand extends StatelessWidget {
  const _StatusAndExpand({required this.status});

  final LineupStatus status;

  @override
  Widget build(BuildContext context) {
    final label = switch (status) {
      LineupStatus.confirmed => 'Confirmada',
      LineupStatus.provisional => 'Provisional',
      LineupStatus.predicted => 'Predicha',
      LineupStatus.unknown => null,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null)
          Text(label, style: const TextStyle(color: muted, fontSize: 10)),
        const Icon(Icons.expand_more_rounded),
      ],
    );
  }
}

class _EntryDetails extends StatelessWidget {
  const _EntryDetails(this.entry);

  final LineupHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    Widget players(String title, List<LineupHistoryPlayer> values) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        for (final player in values)
          Text(
            [
              player.name,
              if (player.minutes != null) '${player.minutes} min',
            ].join(' · '),
            style: const TextStyle(color: muted, fontSize: 12),
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (entry.starters.isNotEmpty) players('XI inicial', entry.starters),
        if (entry.bench.isNotEmpty) ...[
          const SizedBox(height: 10),
          players('Banca', entry.bench),
        ],
        if (entry.coach?.trim().isNotEmpty == true) ...[
          const SizedBox(height: 10),
          Text('Entrenador: ${entry.coach}'),
        ],
        if (entry.captain != null) ...[
          const SizedBox(height: 4),
          Text('Capitán: ${entry.captain!.name}'),
        ],
        if (entry.substitutions.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text(
            'Sustituciones',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          for (final substitution in entry.substitutions)
            Text(
              '${substitution.playerOut.name} → ${substitution.playerIn.name}'
              '${substitution.minute == null ? '' : ' · ${substitution.minute}\''}',
              style: const TextStyle(color: muted, fontSize: 12),
            ),
        ],
      ],
    );
  }
}

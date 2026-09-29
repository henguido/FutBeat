import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';
import '../entities/standings.dart';
import 'match_screen.dart';

// Match Center 2.0 phase 2 (#99): recent form, the two sides' table rows and
// head-to-head. Everything comes from data already loaded (the match
// context snapshot and the separate /v1/match-preview read); nothing here
// makes a request.

const _positive = lime;
const _negative = Color(0xFFE57373);
const _neutral = Color(0xFF9AA5AB);

(String, Color) _resultLabel(TeamResult? result) => switch (result) {
  TeamResult.win => ('V', _positive),
  TeamResult.draw => ('E', _neutral),
  TeamResult.loss => ('D', _negative),
  null => ('–', muted),
};

class _Card extends StatelessWidget {
  const _Card({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .03),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Colors.white.withValues(alpha: .08)),
    ),
    child: child,
  );
}

class _Skeleton extends StatelessWidget {
  const _Skeleton({required this.lines, super.key});

  final int lines;

  @override
  Widget build(BuildContext context) => _Card(
    child: Column(
      children: [
        for (var i = 0; i < lines; i++)
          Container(
            height: 22,
            margin: EdgeInsets.only(top: i == 0 ? 0 : 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .06),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Forma reciente
// ---------------------------------------------------------------------------

/// Last results of both sides, oldest -> newest left to right so each row
/// ends with the most recent result.
class RecentFormSection extends StatelessWidget {
  const RecentFormSection({
    required this.preview,
    required this.data,
    required this.match,
    super.key,
  });

  final AsyncValue<MatchPreview> preview;
  final Snapshot data;
  final FootballMatch match;

  @override
  Widget build(BuildContext context) => preview.when(
    loading: () => const _Skeleton(key: ValueKey('form-loading'), lines: 2),
    error: (_, _) => const _Card(
      key: ValueKey('form-unavailable'),
      child: Text(
        'Forma reciente no disponible por ahora.',
        style: TextStyle(color: muted),
      ),
    ),
    data: (value) => _Card(
      key: const ValueKey('recent-form'),
      child: Column(
        children: [
          _FormRow(
            key: const ValueKey('form-home'),
            team: data.team(match.homeId) ?? value.team(match.homeId),
            teamId: match.homeId,
            accent: lime,
            matches: value.formMatches('home'),
            preview: value,
          ),
          const SizedBox(height: 12),
          _FormRow(
            key: const ValueKey('form-away'),
            team: data.team(match.awayId) ?? value.team(match.awayId),
            teamId: match.awayId,
            accent: awaySideColor,
            matches: value.formMatches('away'),
            preview: value,
          ),
        ],
      ),
    ),
  );
}

class _FormRow extends StatelessWidget {
  const _FormRow({
    required this.team,
    required this.teamId,
    required this.accent,
    required this.matches,
    required this.preview,
    super.key,
  });

  final Entity? team;
  final String teamId;
  final Color accent;

  /// Newest first (as served).
  final List<Json> matches;
  final MatchPreview preview;

  @override
  Widget build(BuildContext context) {
    final chronological = matches.take(5).toList().reversed.toList();
    return Row(
      children: [
        Container(width: 3, height: 30, color: accent),
        const SizedBox(width: 8),
        if (team != null) ...[
          EntityAvatar(team!, size: 26),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(
            team?.name ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: 8),
        if (chronological.isEmpty)
          const Flexible(
            child: Text(
              'Sin partidos recientes',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: TextStyle(color: muted, fontSize: 12),
            ),
          )
        else
          for (final item in chronological)
            _ResultChip(item: item, teamId: teamId, preview: preview),
      ],
    );
  }
}

class _ResultChip extends StatelessWidget {
  const _ResultChip({
    required this.item,
    required this.teamId,
    required this.preview,
  });

  final Json item;
  final String teamId;
  final MatchPreview preview;

  @override
  Widget build(BuildContext context) {
    final (label, color) = _resultLabel(teamMatchResult(item, teamId));
    final home = preview.team(item['homeTeamId'] as String?)?.name ?? 'Local';
    final away = preview.team(item['awayTeamId'] as String?)?.name ?? 'Visita';
    final score = item['score'] is Map
        ? '${item['score']['home']} - ${item['score']['away']}'
        : '–';
    final date = DateTime.tryParse(item['startTime'] as String? ?? '');
    return Tooltip(
      message: [
        '$home $score $away',
        if (date != null) matchDateLabel(costaRicaTime(date)),
      ].join(' · '),
      child: Container(
        width: 26,
        height: 26,
        margin: const EdgeInsets.only(left: 5),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: .16),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: color.withValues(alpha: .5)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Posición en la tabla (from the standings already in the snapshot)
// ---------------------------------------------------------------------------

/// The two sides' rows of the exact competition+season table already loaded
/// by the match context. Hidden without a table. For a finished match it is
/// labelled as the season table (it may not be the table at that date).
class StandingsSnapshotCard extends StatelessWidget {
  const StandingsSnapshotCard({
    required this.data,
    required this.match,
    super.key,
  });

  final Snapshot data;
  final FootballMatch match;

  @override
  Widget build(BuildContext context) {
    // The match's own group (or, across groups, each side's own group); a
    // table that cannot be resolved is hidden.
    final groups = standingsGroups(
      standingsTableFor(data, match.competitionId),
      data,
      focusTeamIds: {match.homeId, match.awayId},
    );
    // Across groups each position is labelled with its own group.
    final crossGroup = (groups?.length ?? 0) > 1;
    (int, Json, String?)? find(String teamId) {
      for (final group in groups ?? const <StandingsGroup>[]) {
        final rows = group.rows;
        for (var i = 0; i < rows.length; i++) {
          if (rows[i]['teamId'] == teamId) {
            return (
              (rows[i]['position'] as num?)?.toInt() ?? i + 1,
              rows[i],
              crossGroup ? group.label : null,
            );
          }
        }
      }
      return null;
    }

    final home = find(match.homeId);
    final away = find(match.awayId);
    if (home == null && away == null) return const SizedBox.shrink();
    final historical = match.isFinished || match.hasPlayedEvidence;
    return Column(
      key: const ValueKey('standings-snapshot'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 14, 2, 8),
          child: Text(
            historical ? 'Tabla de la temporada' : 'Posición en la tabla',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
        ),
        _Card(
          child: Column(
            children: [
              if (home != null)
                _PositionRow(data.team(match.homeId), home, lime),
              if (home != null && away != null) const SizedBox(height: 10),
              if (away != null)
                _PositionRow(data.team(match.awayId), away, awaySideColor),
            ],
          ),
        ),
      ],
    );
  }
}

class _PositionRow extends StatelessWidget {
  const _PositionRow(this.team, this.entry, this.accent);

  final Entity? team;
  final (int, Json, String?) entry;
  final Color accent;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(width: 3, height: 26, color: accent),
      const SizedBox(width: 8),
      if (team != null) ...[
        EntityAvatar(team!, size: 24),
        const SizedBox(width: 8),
      ],
      Expanded(
        child: Text(
          team?.name ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      if (entry.$3 != null) ...[
        Text(entry.$3!, style: const TextStyle(color: muted, fontSize: 12)),
        const SizedBox(width: 8),
      ],
      Text(
        '#${entry.$1}',
        style: TextStyle(color: accent, fontWeight: FontWeight.w900),
      ),
      const SizedBox(width: 14),
      SizedBox(
        width: 56,
        child: Text(
          '${entry.$2['points'] ?? 0} pts',
          textAlign: TextAlign.end,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
    ],
  );
}

// ---------------------------------------------------------------------------
// Cara a cara
// ---------------------------------------------------------------------------

class HeadToHeadTab extends StatefulWidget {
  const HeadToHeadTab({
    required this.preview,
    required this.data,
    required this.match,
    this.onRetry,
    super.key,
  });

  final AsyncValue<MatchPreview> preview;
  final Snapshot data;
  final FootballMatch match;

  /// One manual re-read after a failure (never automatic).
  final VoidCallback? onRetry;

  @override
  State<HeadToHeadTab> createState() => _HeadToHeadTabState();
}

class _HeadToHeadTabState extends State<HeadToHeadTab> {
  /// "Este torneo": only meetings of the selected match's competition.
  bool _thisCompetition = false;

  @override
  Widget build(BuildContext context) => widget.preview.when(
    loading: () => const _Skeleton(key: ValueKey('h2h-loading'), lines: 3),
    error: (_, _) => Column(
      key: const ValueKey('h2h-unavailable'),
      children: [
        const EmptyState(
          'Cara a cara no disponible',
          'No pudimos cargar esta sección.',
          icon: Icons.compare_arrows_rounded,
        ),
        if (widget.onRetry != null)
          OutlinedButton.icon(
            onPressed: widget.onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Reintentar'),
          ),
      ],
    ),
    data: _content,
  );

  Widget _content(MatchPreview value) {
    final match = widget.match;
    Entity? team(String id) => widget.data.team(id) ?? value.team(id);
    final competitionId = value.h2hCompetitionId ?? match.competitionId;
    final all = value.h2hMeetings;
    final current = value.h2hCurrent;
    final availability = value.h2hAvailability;
    if (all.isEmpty && current == null) {
      return switch (availability) {
        'CONFIRMED_EMPTY' => const _H2hMessage(
          'Sin enfrentamientos anteriores',
          key: ValueKey('h2h-empty'),
        ),
        'UNAVAILABLE' => const _H2hMessage(
          'Historial no disponible',
          key: ValueKey('h2h-no-source'),
        ),
        // PENDING / STALE without rows: coverage still arriving.
        _ => const Column(
          key: ValueKey('h2h-pending'),
          children: [
            _Skeleton(lines: 2),
            SizedBox(height: 10),
            Text('Cargando historial', style: TextStyle(color: muted)),
          ],
        ),
      };
    }
    final meetings = _thisCompetition
        ? [
            for (final item in all)
              if (item['competitionId'] == competitionId) item,
          ]
        : all;
    final totals =
        value.h2hTotals(competition: _thisCompetition) ??
        _countTotals(meetings, match.homeId);
    final showCurrent =
        current != null &&
        (!_thisCompetition || current['competitionId'] == competitionId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _H2hSummary(
          home: team(match.homeId),
          away: team(match.awayId),
          totals: totals,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _FilterChip(
              key: const ValueKey('h2h-filter-all'),
              label: 'Todos',
              selected: !_thisCompetition,
              onTap: () => setState(() => _thisCompetition = false),
            ),
            const SizedBox(width: 8),
            _FilterChip(
              key: const ValueKey('h2h-filter-competition'),
              label: 'Este torneo',
              selected: _thisCompetition,
              onTap: () => setState(() => _thisCompetition = true),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (showCurrent) ...[
          _MeetingRow(
            key: const ValueKey('h2h-current'),
            item: current,
            team: team,
            preview: value,
            label: _currentLabel(current),
          ),
          const SizedBox(height: 8),
        ],
        if (meetings.isEmpty)
          const _H2hMessage(
            'Sin enfrentamientos en este torneo',
            key: ValueKey('h2h-empty-competition'),
          )
        else
          for (final item in meetings) ...[
            _MeetingRow(item: item, team: team, preview: value),
            const SizedBox(height: 8),
          ],
      ],
    );
  }

  static String _currentLabel(Json item) =>
      ['LIVE', 'HALFTIME', 'EXTRA_TIME', 'PENALTIES'].contains(item['status'])
      ? 'En vivo'
      : 'Próximo';

  /// Legacy answers (no server totals): count the meetings by team id.
  static H2hTotals _countTotals(List<Json> meetings, String homeId) {
    var homeWins = 0, draws = 0, awayWins = 0;
    for (final item in meetings) {
      switch (teamMatchResult(item, homeId)) {
        case TeamResult.win:
          homeWins++;
        case TeamResult.draw:
          draws++;
        case TeamResult.loss:
          awayWins++;
        case null:
          break;
      }
    }
    return H2hTotals(homeWins: homeWins, draws: draws, awayWins: awayWins);
  }
}

class _H2hMessage extends StatelessWidget {
  const _H2hMessage(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 28),
    child: Center(
      child: Column(
        children: [
          const Icon(Icons.compare_arrows_rounded, color: muted, size: 32),
          const SizedBox(height: 10),
          Text(text, style: const TextStyle(color: muted)),
        ],
      ),
    ),
  );
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ChoiceChip(
    label: Text(label),
    selected: selected,
    onSelected: (_) => onTap(),
    showCheckmark: false,
  );
}

/// Two sides, W · D · W and a bar proportional to the three counts.
class _H2hSummary extends StatelessWidget {
  const _H2hSummary({
    required this.home,
    required this.away,
    required this.totals,
  });

  final Entity? home;
  final Entity? away;
  final H2hTotals totals;

  @override
  Widget build(BuildContext context) {
    Widget side(Entity? entity) => Expanded(
      child: Column(
        children: [
          if (entity != null) EntityAvatar(entity, size: 36),
          const SizedBox(height: 6),
          Text(
            entity?.name ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
    return _Card(
      key: const ValueKey('h2h-summary'),
      child: Column(
        children: [
          Row(children: [side(home), side(away)]),
          const SizedBox(height: 12),
          Row(
            children: [
              _SummaryColumn(
                key: const ValueKey('h2h-home-wins'),
                value: totals.homeWins,
                caption: totals.homeWins == 1 ? 'victoria' : 'victorias',
                color: lime,
              ),
              _SummaryColumn(
                key: const ValueKey('h2h-draws'),
                value: totals.draws,
                caption: totals.draws == 1 ? 'empate' : 'empates',
                color: _neutral,
              ),
              _SummaryColumn(
                key: const ValueKey('h2h-away-wins'),
                value: totals.awayWins,
                caption: totals.awayWins == 1 ? 'victoria' : 'victorias',
                color: awaySideColor,
              ),
            ],
          ),
          if (totals.total > 0) ...[
            const SizedBox(height: 12),
            ClipRRect(
              key: const ValueKey('h2h-bar'),
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 6,
                child: Row(
                  children: [
                    for (final (count, color) in [
                      (totals.homeWins, lime),
                      (totals.draws, _neutral),
                      (totals.awayWins, awaySideColor),
                    ])
                      if (count > 0)
                        Expanded(
                          flex: count,
                          child: ColoredBox(color: color),
                        ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SummaryColumn extends StatelessWidget {
  const _SummaryColumn({
    required this.value,
    required this.caption,
    required this.color,
    super.key,
  });

  final int value;
  final String caption;
  final Color color;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      children: [
        Text(
          '$value',
          style: TextStyle(
            color: color,
            fontSize: 26,
            fontWeight: FontWeight.w900,
          ),
        ),
        Text(caption, style: const TextStyle(color: muted, fontSize: 11)),
      ],
    ),
  );
}

class _MeetingRow extends StatelessWidget {
  const _MeetingRow({
    required this.item,
    required this.team,
    required this.preview,
    this.label,
    super.key,
  });

  final Json item;
  final Entity? Function(String id) team;
  final MatchPreview preview;

  /// Status of the selected match when it is not final (never counted).
  final String? label;

  @override
  Widget build(BuildContext context) {
    final id = item['matchId'] as String?;
    final home = team(item['homeTeamId'] as String? ?? '');
    final away = team(item['awayTeamId'] as String? ?? '');
    final date = DateTime.tryParse(item['startTime'] as String? ?? '');
    final score = item['score'] is Map
        ? '${item['score']['home']} - ${item['score']['away']}'
        : '–';
    final competition = preview.competitionName(
      item['competitionId'] as String?,
    );
    Widget side(Entity? entity, {required bool end}) => Expanded(
      child: Row(
        mainAxisAlignment: end
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          if (!end && entity != null) ...[
            EntityAvatar(entity, size: 22),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              entity?.name ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: end ? TextAlign.end : TextAlign.start,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          if (end && entity != null) ...[
            const SizedBox(width: 6),
            EntityAvatar(entity, size: 22),
          ],
        ],
      ),
    );
    return InkWell(
      key: label == null ? ValueKey('h2h-match-$id') : null,
      borderRadius: BorderRadius.circular(14),
      // The selected match itself is already open.
      onTap: id == null || label != null
          ? null
          : () => context.push('/match/$id'),
      child: _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              [
                ?label,
                if (date != null) matchDateLabel(costaRicaTime(date)),
                ?competition,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: muted, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                side(home, end: false),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    score,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                side(away, end: true),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

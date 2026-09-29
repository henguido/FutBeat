import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
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
    // The match's own group only; a table that cannot be resolved is hidden.
    final groups = standingsGroups(
      standingsTableFor(data, match.competitionId),
      data,
      focusTeamIds: {match.homeId, match.awayId},
    );
    final rows = groups?.length == 1 ? groups!.single.rows : const <Json>[];
    (int, Json)? find(String teamId) {
      for (var i = 0; i < rows.length; i++) {
        if (rows[i]['teamId'] == teamId) {
          return ((rows[i]['position'] as num?)?.toInt() ?? i + 1, rows[i]);
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
  final (int, Json) entry;
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

class HeadToHeadTab extends ConsumerStatefulWidget {
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
  ConsumerState<HeadToHeadTab> createState() => _HeadToHeadTabState();
}

class _HeadToHeadTabState extends ConsumerState<HeadToHeadTab> {
  /// "Este torneo": only meetings of the selected match's competition.
  bool _thisCompetition = false;

  /// Server pages per scope (false = Todos, true = Este torneo). Once a
  /// scope has pages, they replace the preview's first meetings: the server
  /// order and totals are the only source from then on.
  final Map<bool, List<H2hPage>> _pages = {false: [], true: []};
  final Set<bool> _loading = {};
  final Set<bool> _failed = {};

  /// Older-history extension (central coverage, both teams).
  bool _extending = false;
  bool _extendPending = false;
  bool? _canExtend;
  String? _verifiedFrom;
  Timer? _poll;

  /// Bumped when an extension lands: page answers of the older list are
  /// dropped.
  int _generation = 0;

  /// After an extension the preview's first meetings/totals are outdated:
  /// every scope is read from the server.
  bool _previewStale = false;

  /// Todos rows shown when the extension was asked (re-read that many).
  int _shownAll = 0;

  /// Re-reads while the extension is in flight; then it is left pending.
  static const extendPollDelays = [
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 60),
  ];

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  ApiRepository? get _api {
    final repository = ref.read(repositoryProvider);
    return repository is ApiRepository ? repository : null;
  }

  /// The first page asks from the top (no cursor) for what the preview
  /// showed plus one more page, so ties and gaps in the preview's cut never
  /// hide a meeting; later pages follow the server's cursor.
  Future<void> _loadMore(bool competition, int shown) async {
    final api = _api;
    if (api == null || _loading.contains(competition)) return;
    final pages = _pages[competition]!;
    final generation = _generation;
    setState(() {
      _loading.add(competition);
      _failed.remove(competition);
    });
    try {
      final page = await api.loadMatchH2h(
        widget.match.id,
        scope: competition ? 'competition' : 'all',
        cursor: pages.isEmpty ? null : pages.last.nextCursor,
        limit: pages.isEmpty ? math.min(50, shown + 20) : 20,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _pages[competition]!.add(page);
        _verifiedFrom = page.verifiedFrom ?? _verifiedFrom;
        _canExtend = page.canExtend;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _failed.add(competition));
      }
    } finally {
      if (mounted) setState(() => _loading.remove(competition));
    }
  }

  int get _rereadLimit => math.min(50, math.max(20, _shownAll));

  Future<void> _extend() async {
    final api = _api;
    if (api == null || _extending) return;
    setState(() => _extending = true);
    try {
      _settle(
        await api.loadMatchH2h(
          widget.match.id,
          extend: true,
          limit: _rereadLimit,
        ),
        0,
      );
    } catch (_) {
      if (mounted) setState(() => _extending = false);
    }
  }

  /// Applies an extension answer: done -> fresh first page of Todos (new
  /// meetings and totals); still in flight -> re-read later, a bounded
  /// number of times, then left as pending.
  void _settle(H2hPage page, int attempt) {
    if (!mounted) return;
    if (!page.extending) {
      setState(() {
        _generation++;
        _extending = false;
        _previewStale = true;
        _pages[false] = [page];
        _pages[true] = [];
        _loading.clear();
        _failed.clear();
        _verifiedFrom = page.verifiedFrom ?? _verifiedFrom;
        _canExtend = page.canExtend;
      });
      if (_thisCompetition) _loadMore(true, 0);
      return;
    }
    if (attempt >= extendPollDelays.length) {
      setState(() {
        _extending = false;
        _extendPending = true;
      });
      return;
    }
    _poll = Timer(extendPollDelays[attempt], () async {
      final api = _api;
      if (api == null || !mounted) return;
      try {
        _settle(
          await api.loadMatchH2h(widget.match.id, limit: _rereadLimit),
          attempt + 1,
        );
      } catch (_) {
        if (mounted) {
          setState(() {
            _extending = false;
            _extendPending = true;
          });
        }
      }
    });
  }

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
    final loaded = [..._pages[false]!, ..._pages[true]!];
    Entity? team(String id) =>
        widget.data.team(id) ??
        value.team(id) ??
        loaded.map((p) => p.teams[id]).nonNulls.firstOrNull;
    String? competitionName(String? id) =>
        value.competitionName(id) ??
        (id == null
            ? null
            : loaded.map((p) => p.competitions[id]).nonNulls.firstOrNull);
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
    final base = _thisCompetition
        ? [
            for (final item in all)
              if (item['competitionId'] == competitionId) item,
          ]
        : all;
    final pages = _pages[_thisCompetition]!;
    // Before any page: the preview's newest meetings. After: the server's
    // pages only, each id once.
    final seen = <String>{};
    final meetings = [
      for (final item in pages.isEmpty ? base : pages.expand((p) => p.meetings))
        if (seen.add(item['matchId']?.toString() ?? '')) item,
    ];
    final totals =
        (pages.isEmpty ? null : pages.last.totals) ??
        value.h2hTotals(competition: _thisCompetition) ??
        _countTotals(meetings, match.homeId);
    // More stored meetings than shown: the server said so, or (before any
    // page) the scope's totals count more than the preview listed.
    final more = pages.isNotEmpty
        ? pages.last.hasMore
        : meetings.length < totals.total;
    final verifiedFrom = _verifiedFrom ?? value.h2hVerifiedFrom;
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
              onTap: () {
                setState(() => _thisCompetition = true);
                if (_previewStale && _pages[true]!.isEmpty) _loadMore(true, 0);
              },
            ),
          ],
        ),
        if (verifiedFrom != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Historial verificado desde ${_monthYear(verifiedFrom)}',
              key: const ValueKey('h2h-window'),
              style: const TextStyle(color: muted, fontSize: 12),
            ),
          ),
        const SizedBox(height: 12),
        if (showCurrent) ...[
          _MeetingRow(
            key: const ValueKey('h2h-current'),
            item: current,
            team: team,
            competitionName: competitionName,
            label: _currentLabel(current),
          ),
          const SizedBox(height: 8),
        ],
        if (meetings.isEmpty && !more)
          const _H2hMessage(
            'Sin enfrentamientos en este torneo',
            key: ValueKey('h2h-empty-competition'),
          )
        else
          for (final item in meetings) ...[
            _MeetingRow(
              item: item,
              team: team,
              competitionName: competitionName,
            ),
            const SizedBox(height: 8),
          ],
        if (_loading.contains(_thisCompetition))
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Center(
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if ((more || _failed.contains(_thisCompetition)) && _api != null)
          Center(
            child: TextButton(
              key: const ValueKey('h2h-more'),
              onPressed: () => _loadMore(_thisCompetition, meetings.length),
              child: Text(
                _failed.contains(_thisCompetition) ? 'Reintentar' : 'Ver más',
              ),
            ),
          )
        else if (_extending)
          const Padding(
            key: ValueKey('h2h-extending'),
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Center(
              child: Text('Cargando historial', style: TextStyle(color: muted)),
            ),
          )
        else if (_extendPending)
          const Padding(
            key: ValueKey('h2h-extend-pending'),
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Center(
              child: Text(
                'Historial pendiente',
                style: TextStyle(color: muted),
              ),
            ),
          )
        else if (verifiedFrom != null && _canExtend != false && _api != null)
          Center(
            child: TextButton(
              key: const ValueKey('h2h-extend'),
              onPressed: () {
                if (!_thisCompetition) _shownAll = meetings.length;
                _extend();
              },
              child: const Text('Cargar historial anterior'),
            ),
          ),
      ],
    );
  }

  static const _months = [
    'ene',
    'feb',
    'mar',
    'abr',
    'may',
    'jun',
    'jul',
    'ago',
    'sep',
    'oct',
    'nov',
    'dic',
  ];

  static String _monthYear(String date) {
    final parsed = DateTime.tryParse(date);
    return parsed == null
        ? date
        : '${_months[parsed.month - 1]} ${parsed.year}';
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
    required this.competitionName,
    this.label,
    super.key,
  });

  final Json item;
  final Entity? Function(String id) team;
  final String? Function(String? id) competitionName;

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
    final competition = competitionName(item['competitionId'] as String?);
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

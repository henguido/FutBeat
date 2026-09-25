import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';

/// How a standings table is laid out.
enum StandingsView {
  /// Mobile-first: Pos · Equipo · PJ · DG · Pts, no horizontal scroll.
  compact,

  /// Every column (Pos · Equipo · PJ · G · E · P · GF · GC · DG · Pts),
  /// horizontally scrollable when the screen is narrow.
  full,
}

/// Teams of [competitionId] that the snapshot itself shows in play. Evidence
/// is only a real in-play status in `data.matches` (live overlays included):
/// never the kickoff time.
Set<String> liveTeamIds(Snapshot data, String competitionId) => {
  for (final match in data.matches)
    if (match.competitionId == competitionId && match.isLive) ...[
      match.homeId,
      match.awayId,
    ],
};

class Standings extends StatefulWidget {
  const Standings(
    this.data,
    this.competitionId, {
    super.key,
    this.highlightedTeams = const {},
    this.liveTeamIds = const {},
    this.selectableView = false,
  });

  final Snapshot data;
  final String competitionId;

  /// Team id -> accent color (e.g. the selected match's home/away sides).
  final Map<String, Color> highlightedTeams;

  /// Teams currently in play (see [liveTeamIds]).
  final Set<String> liveTeamIds;

  /// Show the local "Resumida | Completa" switch (default Resumida). Without
  /// it the full table is shown, as on competition/team screens.
  final bool selectableView;

  @override
  State<Standings> createState() => _StandingsState();
}

class _StandingsState extends State<Standings> {
  StandingsView _view = StandingsView.compact;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final table = data.standings
        .where((s) => s['competitionId'] == widget.competitionId)
        .firstOrNull;
    final rows = (table?['rows'] as List? ?? const []).cast<Json>();
    if (table == null || rows.isEmpty) {
      return const EmptyState(
        'Tabla no disponible',
        'La clasificación aparecerá cuando exista una fuente disponible.',
      );
    }
    final view = widget.selectableView ? _view : StandingsView.full;
    final entries = [
      for (var i = 0; i < rows.length; i++) _Entry.from(rows[i], i, data),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        heading(context, 'Clasificación'),
        Text(
          data.demo
              ? 'Tabla de ejemplo · no se recalcula en vivo'
              : table['provisional'] == true
              ? 'Tabla provisional'
              : 'Última tabla publicada',
          style: const TextStyle(color: muted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        // Its own row above the table: never squeezes the title on a
        // narrow phone.
        if (widget.selectableView) ...[
          _ViewSwitch(
            view: _view,
            onChanged: (view) => setState(() => _view = view),
          ),
          const SizedBox(height: 10),
        ],
        if (view == StandingsView.compact)
          _Table(
            key: const ValueKey('standings-compact'),
            entries: entries,
            columns: _compactColumns,
            highlightedTeams: widget.highlightedTeams,
            liveTeamIds: widget.liveTeamIds,
          )
        else
          LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: constraints.maxWidth,
                  maxWidth: constraints.maxWidth > _fullMinWidth
                      ? constraints.maxWidth
                      : _fullMinWidth,
                ),
                child: _Table(
                  key: const ValueKey('standings-full'),
                  entries: entries,
                  columns: _fullColumns,
                  highlightedTeams: widget.highlightedTeams,
                  liveTeamIds: widget.liveTeamIds,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Minimum width of the full table before it scrolls horizontally.
const double _fullMinWidth = 560;

class _Entry {
  _Entry({
    required this.teamId,
    required this.team,
    required this.position,
    required this.values,
  });

  factory _Entry.from(Json row, int index, Snapshot data) {
    final teamId = row['teamId']?.toString() ?? '';
    int value(String key) => (row[key] as num?)?.toInt() ?? 0;
    final gf = value('gf');
    final ga = value('ga');
    return _Entry(
      teamId: teamId,
      team: data.team(teamId),
      position: (row['position'] as num?)?.toInt() ?? index + 1,
      values: {
        'played': value('played'),
        'won': value('won'),
        'drawn': value('drawn'),
        'lost': value('lost'),
        'gf': gf,
        'ga': ga,
        'diff': gf - ga,
        'points': value('points'),
      },
    );
  }

  final String teamId;
  final Entity? team;
  final int position;
  final Map<String, int> values;

  String get name => team?.name ?? 'Equipo';
}

class _Column {
  const _Column(this.label, this.key, {this.width = 32, this.semantic});

  final String label;
  final String key;
  final double width;
  final String? semantic;
}

const _compactColumns = [
  _Column('PJ', 'played', semantic: 'jugados'),
  _Column('DG', 'diff', width: 38, semantic: 'diferencia de gol'),
  _Column('Pts', 'points', width: 38, semantic: 'puntos'),
];

const _fullColumns = [
  _Column('PJ', 'played', semantic: 'jugados'),
  _Column('G', 'won', semantic: 'ganados'),
  _Column('E', 'drawn', semantic: 'empatados'),
  _Column('P', 'lost', semantic: 'perdidos'),
  _Column('GF', 'gf', semantic: 'goles a favor'),
  _Column('GC', 'ga', semantic: 'goles en contra'),
  _Column('DG', 'diff', width: 38, semantic: 'diferencia de gol'),
  _Column('Pts', 'points', width: 38, semantic: 'puntos'),
];

class _Table extends StatelessWidget {
  const _Table({
    required this.entries,
    required this.columns,
    required this.highlightedTeams,
    required this.liveTeamIds,
    super.key,
  });

  final List<_Entry> entries;
  final List<_Column> columns;
  final Map<String, Color> highlightedTeams;
  final Set<String> liveTeamIds;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .03),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Colors.white.withValues(alpha: .08)),
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Column(
        children: [
          _HeaderRow(columns),
          for (var i = 0; i < entries.length; i++)
            _TeamRow(
              entry: entries[i],
              columns: columns,
              accent: highlightedTeams[entries[i].teamId],
              live: liveTeamIds.contains(entries[i].teamId),
              divider: i > 0,
            ),
        ],
      ),
    ),
  );
}

const _numberStyle = TextStyle(
  fontSize: 13,
  fontFeatures: [FontFeature.tabularFigures()],
);

class _HeaderRow extends StatelessWidget {
  const _HeaderRow(this.columns);

  final List<_Column> columns;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      color: muted,
      fontSize: 11,
      fontWeight: FontWeight.w800,
      letterSpacing: .4,
    );
    return Container(
      color: Colors.white.withValues(alpha: .04),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Row(
        children: [
          const SizedBox(width: 28, child: _HeaderLabel('Pos', style)),
          const SizedBox(width: 8),
          const Expanded(child: Text('Equipo', style: style)),
          for (final column in columns)
            SizedBox(
              width: column.width,
              child: _HeaderLabel(column.label, style),
            ),
        ],
      ),
    );
  }
}

/// A column label that never wraps (scales down with large text instead).
class _HeaderLabel extends StatelessWidget {
  const _HeaderLabel(this.label, this.style);

  final String label;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    child: Text(label, style: style, maxLines: 1, softWrap: false),
  );
}

class _TeamRow extends StatelessWidget {
  const _TeamRow({
    required this.entry,
    required this.columns,
    required this.accent,
    required this.live,
    required this.divider,
  });

  final _Entry entry;
  final List<_Column> columns;
  final Color? accent;
  final bool live;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final highlighted = accent != null;
    final team = entry.team;
    String number(_Column column) {
      final value = entry.values[column.key] ?? 0;
      return column.key == 'diff' && value > 0 ? '+$value' : '$value';
    }

    return Semantics(
      container: true,
      button: entry.teamId.isNotEmpty,
      label: [
        'Posición ${entry.position}',
        entry.name,
        if (live) 'en vivo',
        for (final column in columns)
          '${number(column)} ${column.semantic ?? column.label}',
      ].join(', '),
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('standings-row-${entry.teamId}'),
        onTap: entry.teamId.isEmpty
            ? null
            : () => context.push('/team/${entry.teamId}'),
        child: Container(
          constraints: const BoxConstraints(minHeight: 46),
          decoration: BoxDecoration(
            color: highlighted ? accent!.withValues(alpha: .09) : null,
            border: Border(
              left: BorderSide(color: accent ?? Colors.transparent, width: 3),
              top: divider
                  ? BorderSide(color: Colors.white.withValues(alpha: .06))
                  : BorderSide.none,
            ),
          ),
          padding: const EdgeInsets.fromLTRB(7, 6, 10, 6),
          child: Row(
            children: [
              SizedBox(
                width: 28,
                child: Text(
                  '${entry.position}',
                  textAlign: TextAlign.center,
                  style: _numberStyle.copyWith(
                    color: highlighted ? accent : muted,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (team != null) ...[
                EntityAvatar(team, size: 22),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  entry.name,
                  key: ValueKey('standings-name-${entry.teamId}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: highlighted ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ),
              if (live) ...[const SizedBox(width: 6), const _LiveBadge()],
              for (final column in columns)
                SizedBox(
                  width: column.width,
                  child: Text(
                    number(column),
                    textAlign: TextAlign.center,
                    style: column.key == 'points'
                        ? _numberStyle.copyWith(
                            fontWeight: FontWeight.w900,
                            color: lime,
                          )
                        : _numberStyle,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('standings-live'),
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
    decoration: BoxDecoration(
      color: Colors.redAccent.withValues(alpha: .16),
      borderRadius: BorderRadius.circular(6),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 6, color: Colors.redAccent),
        SizedBox(width: 3),
        Text(
          'EN VIVO',
          style: TextStyle(
            color: Colors.redAccent,
            fontSize: 9.5,
            fontWeight: FontWeight.w900,
            letterSpacing: .3,
          ),
        ),
      ],
    ),
  );
}

class _ViewSwitch extends StatelessWidget {
  const _ViewSwitch({required this.view, required this.onChanged});

  final StandingsView view;
  final ValueChanged<StandingsView> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .06),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (option, label) in [
          (StandingsView.compact, 'Resumida'),
          (StandingsView.full, 'Completa'),
        ])
          Semantics(
            button: true,
            selected: option == view,
            child: InkWell(
              key: ValueKey('standings-view-${option.name}'),
              borderRadius: BorderRadius.circular(999),
              onTap: () => onChanged(option),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                constraints: const BoxConstraints(minHeight: 32),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: option == view ? lime : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: option == view ? Colors.black : muted,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

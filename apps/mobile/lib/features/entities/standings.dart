import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';

/// How a standings table is laid out.
enum StandingsView {
  /// Mobile-first: Pos · Equipo · J · DG · Pts, no horizontal scroll.
  compact,

  /// Every column (Pos · Equipo · J · G · E · P · GF · GC · DG · Pts),
  /// horizontally scrollable when the screen is narrow.
  full,

  /// Pos · Equipo · last results (G/E/P, newest first) · Pts. Loaded lazily
  /// from the server the first time it is opened; real results only.
  form,
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

/// One displayable group of a standings table ([label] null for a single,
/// unnamed table).
typedef StandingsGroup = ({String? label, List<Json> rows});

/// Label shown on the unlabelled table (the competition's overall/annual
/// table) when the stored table also has labelled groups.
const overallStandingsLabel = 'Tabla general';

/// Normalized tokens of a stage or group label: lower case, accents folded,
/// split on anything that is not a letter or digit.
Set<String> standingsLabelTokens(String? text) {
  const from = 'áàâäãåéèêëíìîïóòôöõúùûüñç';
  const to = 'aaaaaaeeeeiiiiooooouuuunc';
  final buffer = StringBuffer();
  for (final char in (text ?? '').toLowerCase().split('')) {
    final i = from.indexOf(char);
    buffer.write(i < 0 ? char : to[i]);
  }
  return {
    for (final token in buffer.toString().split(RegExp('[^a-z0-9]+')))
      if (token.isNotEmpty) token,
  };
}

/// The groups of [table] that can be shown, or null when the table must not
/// be shown at all ("Tabla no disponible"):
///  * no rows, or the server could not tell its groups apart;
///  * a row whose team entity is unknown (never a placeholder name);
///  * a repeated position inside one group (unlabelled groups mixed).
/// Without [focusTeamIds], every group; the unlabelled one is labelled
/// [overallStandingsLabel] when labelled groups are shown with it.
/// With one group and [focusTeamIds], it is shown only when it holds every
/// focus team; otherwise the table is unavailable.
/// With [focusTeamIds] and several groups:
///  * one group holds every focus team: only that group (a team profile
///    shows the team's group, a Match Center the match's group);
///  * several groups hold them all (e.g. the annual table plus one table per
///    season phase), the current phase is chosen, never mixed:
///     1. [stage] (the match's provider stage, Match Center) names exactly
///        one labelled group of the table (every normalized token of the
///        label is in the stage, see [standingsLabelTokens]) and that group
///        holds them all: that group;
///     2. the table's server hint `currentGroup` (every recent match of the
///        competition was played in that phase) is a labelled group holding
///        them all: that group;
///     3. exactly one of them is unlabelled: that one, the competition's
///        overall table, labelled [overallStandingsLabel];
///     4. otherwise (e.g. "Grupo A" plus a ranking of third-placed teams):
///        null, the right one cannot be told;
///  * no group holds them all (a knockout between teams of different
///    groups): each focus team's own group, as separate labelled tables,
///    never merged. Null when a focus team is in no group or in more than
///    one, or when one of those groups has no label.
List<StandingsGroup>? standingsGroups(
  Json? table,
  Snapshot data, {
  Set<String> focusTeamIds = const {},
  String? stage,
}) {
  final rows = (table?['rows'] as List? ?? const []).cast<Json>();
  if (table == null || rows.isEmpty || table['groupsResolved'] == false) {
    return null;
  }
  final groups = <String, List<Json>>{};
  for (final row in rows) {
    final teamId = row['teamId']?.toString() ?? '';
    if (standingsTeam(data, teamId) == null) return null;
    groups.putIfAbsent(row['group']?.toString() ?? '', () => []).add(row);
  }
  for (final group in groups.values) {
    final positions = [
      for (final row in group)
        if (row['position'] != null) (row['position'] as num).toInt(),
    ];
    if (positions.toSet().length != positions.length) return null;
  }
  final all = [
    for (final entry in groups.entries)
      (label: entry.key.isEmpty ? null : entry.key, rows: entry.value),
  ];
  StandingsGroup labelled(StandingsGroup group) =>
      group.label == null && all.any((other) => other.label != null)
      ? (label: overallStandingsLabel, rows: group.rows)
      : group;
  if (focusTeamIds.isEmpty) {
    return [for (final group in all) labelled(group)];
  }
  bool holds(StandingsGroup group, String id) => group.rows.any(
    (row) =>
        data.resolveEntityId(row['teamId']?.toString() ?? '') ==
        data.resolveEntityId(id),
  );
  if (all.length == 1) {
    return focusTeamIds.every((id) => holds(all.single, id))
        ? [labelled(all.single)]
        : null;
  }
  final whole = [
    for (final group in all)
      if (focusTeamIds.every((id) => holds(group, id))) group,
  ];
  if (whole.length > 1) {
    // 1. The match's own stage names one labelled group of the table.
    final stageTokens = standingsLabelTokens(stage);
    if (stageTokens.isNotEmpty) {
      final named = [
        for (final group in all)
          if (group.label != null)
            if (standingsLabelTokens(group.label) case final tokens
                when tokens.isNotEmpty && stageTokens.containsAll(tokens))
              group,
      ];
      if (named.length == 1 && whole.contains(named.single)) {
        return [named.single];
      }
    }
    // 2. The server's evidence-based current phase.
    final current = table['currentGroup']?.toString().trim() ?? '';
    if (current.isNotEmpty) {
      final hinted = [
        for (final group in whole)
          if (group.label == current) group,
      ];
      if (hinted.length == 1) return hinted;
    }
    // 3. The overall table, labelled as such; 4. ambiguous: nothing.
    final overall = [
      for (final group in whole)
        if (group.label == null) group,
    ];
    return overall.length == 1 ? [labelled(overall.single)] : null;
  }
  if (whole.isNotEmpty) return [labelled(whole.single)];
  final picked = <int>{};
  for (final id in focusTeamIds) {
    final candidates = [
      for (var i = 0; i < all.length; i++)
        if (holds(all[i], id)) i,
    ];
    if (candidates.length != 1) return null;
    picked.add(candidates.single);
  }
  final own = [for (final i in picked.toList()..sort()) all[i]];
  return own.any((group) => group.label == null) ? null : own;
}

/// The team entity of a standings row, also when the row was stored under
/// an alias id the snapshot redirects to its canonical team.
Entity? standingsTeam(Snapshot data, String teamId) => teamId.isEmpty
    ? null
    : data.team(teamId) ?? data.team(data.resolveEntityId(teamId));

/// Season of [table] for the Forma read: its exact key (`seasonKey`, set
/// when the table was filed) or its own label. Null when the table carries
/// neither: Forma is then hidden, never guessed from the competition's
/// current season (an old table at a rollover would get the new season).
String? standingsSeason(Json table) {
  for (final value in [table['seasonKey'], table['season']]) {
    final text = value?.toString().trim() ?? '';
    if (text.isNotEmpty && text.length <= 20) return text;
  }
  return null;
}

/// The table of [competitionId] in [data] (first one), if any.
Json? standingsTableFor(Snapshot data, String competitionId) => data.standings
    .where((s) => s['competitionId'] == competitionId)
    .firstOrNull;

class Standings extends StatefulWidget {
  const Standings(
    this.data,
    this.competitionId, {
    super.key,
    this.highlightedTeams = const {},
    this.liveTeamIds = const {},
    this.selectableView = true,
    this.focusTeamIds = const {},
    this.season,
    this.stage,
  });

  final Snapshot data;
  final String competitionId;

  /// Teams whose group is shown when the table has several groups (see
  /// [standingsGroups]). A single focus team without [highlightedTeams] is
  /// highlighted (team profile).
  final Set<String> focusTeamIds;

  /// The match's provider stage (Match Center): picks the phase table when
  /// several groups hold the focus teams (see [standingsGroups]).
  final String? stage;

  /// Team id -> accent color (e.g. the selected match's home/away sides).
  final Map<String, Color> highlightedTeams;

  /// Teams currently in play (see [liveTeamIds]).
  final Set<String> liveTeamIds;

  /// Show the local "Resumida | Completa | Forma" switch (default Resumida).
  /// Without it only the full table is shown.
  final bool selectableView;

  /// Season of the table for the Forma read (default: [standingsSeason]).
  final String? season;

  @override
  State<Standings> createState() => _StandingsState();
}

/// What one Forma read is for: a competition, the table's season and, for a
/// published (non-provisional) table, its updatedAt as the upper bound.
typedef _FormIdentity = ({String competitionId, String season, String? until});

class _StandingsState extends State<Standings> {
  StandingsView _view = StandingsView.compact;
  bool _restored = false;

  // Forma: loaded once per identity, only when opened.
  _FormIdentity? _formKey;
  StandingsForm? _form;
  bool _formLoading = false;
  bool _formFailed = false;

  String get _storageId {
    final table = standingsTableFor(widget.data, widget.competitionId);
    final season = table == null ? null : _season(table);
    return 'standings-view-${widget.competitionId}-${season ?? ''}';
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restored) return;
    _restored = true;
    // The chosen view survives leaving and coming back to the tab.
    final saved = PageStorage.maybeOf(context)
        ?.readState(context, identifier: _storageId);
    if (saved is StandingsView) _view = saved;
  }

  @override
  void didUpdateWidget(Standings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_formKey != null && _formKey != _formIdentity()) {
      // Another table (competition/season/publication): read Forma again.
      _formKey = null;
      _form = null;
      _formFailed = false;
      _formLoading = false;
    }
  }

  /// The API repository when the app reads the cloud (demo/tests: null).
  ApiRepository? _api() {
    try {
      final repository = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(repositoryProvider);
      return repository is ApiRepository ? repository : null;
    } on StateError {
      return null;
    }
  }

  String? _season(Json table) => widget.season?.trim().isNotEmpty == true
      ? widget.season!.trim()
      : standingsSeason(table);

  /// The Forma read of the current table, or null when Forma is hidden.
  _FormIdentity? _formIdentity() {
    if (!widget.selectableView || widget.data.demo || _api() == null) {
      return null;
    }
    final table = standingsTableFor(widget.data, widget.competitionId);
    final season = table == null ? null : _season(table);
    if (table == null || season == null) return null;
    // Only a parseable timestamp is sent (normalized to UTC ISO 8601): a
    // legacy or bare value is dropped rather than failing every read.
    final updatedAt = DateTime.tryParse(table['updatedAt']?.toString() ?? '');
    return (
      competitionId: widget.competitionId,
      season: season,
      // A provisional table already includes recent results: no bound.
      until: table['provisional'] == true || updatedAt == null
          ? null
          : updatedAt.toUtc().toIso8601String(),
    );
  }

  void _select(StandingsView view) {
    setState(() => _view = view);
    PageStorage.maybeOf(context)
        ?.writeState(context, view, identifier: _storageId);
  }

  Future<void> _loadForm(_FormIdentity identity) async {
    final api = _api();
    if (api == null || _formLoading) return;
    setState(() {
      _formKey = identity;
      _formLoading = true;
      _formFailed = false;
    });
    try {
      final form = await api.loadStandingsForm(
        identity.competitionId,
        identity.season,
        until: identity.until,
      );
      if (mounted && _formKey == identity) setState(() => _form = form);
    } catch (_) {
      if (mounted && _formKey == identity) setState(() => _formFailed = true);
    } finally {
      if (mounted && _formKey == identity) {
        setState(() => _formLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final table = standingsTableFor(data, widget.competitionId);
    final groups = standingsGroups(
      table,
      data,
      focusTeamIds: widget.focusTeamIds,
      stage: widget.stage,
    );
    if (table == null || groups == null) {
      return const Padding(
        key: ValueKey('standings-unavailable'),
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Column(
          children: [
            Icon(Icons.table_rows_outlined, size: 36, color: muted),
            SizedBox(height: 10),
            Text('Tabla no disponible', style: TextStyle(color: muted)),
          ],
        ),
      );
    }
    final formIdentity = _formIdentity();
    final views = [
      StandingsView.compact,
      StandingsView.full,
      if (formIdentity != null) StandingsView.form,
    ];
    final view = !widget.selectableView
        ? StandingsView.full
        : views.contains(_view)
        ? _view
        : StandingsView.compact;
    if (view == StandingsView.form &&
        _form == null &&
        !_formLoading &&
        !_formFailed) {
      // Lazy: the first time Forma is shown (tap or restored view).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _form == null && !_formLoading && !_formFailed) {
          _loadForm(formIdentity!);
        }
      });
    }
    final highlighted =
        widget.highlightedTeams.isEmpty && widget.focusTeamIds.length == 1
        ? {widget.focusTeamIds.single: lime}
        : widget.highlightedTeams;
    Widget tableOf(List<_Entry> entries) => switch (view) {
      StandingsView.compact => _Table(
        key: const ValueKey('standings-compact'),
        entries: entries,
        columns: _compactColumns,
        highlightedTeams: highlighted,
        liveTeamIds: widget.liveTeamIds,
      ),
      StandingsView.form => _Table(
        key: const ValueKey('standings-form'),
        entries: entries,
        columns: _formColumns,
        highlightedTeams: highlighted,
        liveTeamIds: widget.liveTeamIds,
        form: _form,
      ),
      StandingsView.full => LayoutBuilder(
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
              highlightedTeams: highlighted,
              liveTeamIds: widget.liveTeamIds,
            ),
          ),
        ),
      ),
    };
    final formPending = view == StandingsView.form && _form == null;
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
          _ViewSwitch(views: views, view: view, onChanged: _select),
          const SizedBox(height: 10),
        ],
        if (formPending)
          _FormStatus(
            failed: _formFailed,
            onRetry: () => _loadForm(formIdentity!),
          )
        else
          for (var g = 0; g < groups.length; g++) ...[
            if (groups[g].label != null)
              Padding(
                padding: EdgeInsets.only(top: g == 0 ? 0 : 14, bottom: 6),
                child: Text(
                  groups[g].label!,
                  key: ValueKey('standings-group-${groups[g].label}'),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            KeyedSubtree(
              key: ValueKey('standings-table-$g'),
              child: tableOf([
                for (var i = 0; i < groups[g].rows.length; i++)
                  _Entry.from(groups[g].rows[i], i, data),
              ]),
            ),
          ],
      ],
    );
  }
}

/// Forma not loaded yet: a bounded single read, then "Reintentar".
class _FormStatus extends StatelessWidget {
  const _FormStatus({required this.failed, required this.onRetry});

  final bool failed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Center(
      child: failed
          ? Column(
              key: const ValueKey('standings-form-failed'),
              children: [
                const Text(
                  'Forma no disponible',
                  style: TextStyle(color: muted),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const ValueKey('standings-form-retry'),
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Reintentar'),
                ),
              ],
            )
          : const SizedBox(
              key: ValueKey('standings-form-loading'),
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
    ),
  );
}

/// Minimum width of the full table before it scrolls horizontally.
const double _fullMinWidth = 560;

class _Entry {
  _Entry({
    required this.teamId,
    required this.formTeamId,
    required this.team,
    required this.position,
    required this.values,
  });

  factory _Entry.from(Json row, int index, Snapshot data) {
    final teamId = row['teamId']?.toString() ?? '';
    int? value(String key) {
      final raw = row[key];
      if (raw is! num ||
          !raw.isFinite ||
          raw != raw.roundToDouble() ||
          (key != 'points' && raw < 0)) {
        return null;
      }
      return raw.toInt();
    }

    final gf = value('gf');
    final ga = value('ga');
    return _Entry(
      teamId: teamId,
      formTeamId: data.resolveEntityId(teamId),
      // standingsGroups only lets through rows whose team is known.
      team: standingsTeam(data, teamId)!,
      position: (row['position'] as num?)?.toInt() ?? index + 1,
      values: {
        'played': value('played'),
        'won': value('won'),
        'drawn': value('drawn'),
        'lost': value('lost'),
        'gf': gf,
        'ga': ga,
        'diff': gf != null && ga != null ? gf - ga : null,
        'points': value('points'),
      },
    );
  }

  final String teamId;

  /// [teamId] through the snapshot's entity redirects (canonical id).
  final String formTeamId;
  final Entity team;
  final int position;
  final Map<String, int?> values;

  String get name => team.displayName;
}

class _Column {
  const _Column(this.label, this.key, {this.width = 32, this.semantic});

  final String label;
  final String key;
  final double width;
  final String? semantic;
}

const _compactColumns = [
  _Column('J', 'played', semantic: 'jugados'),
  _Column('DG', 'diff', width: 38, semantic: 'diferencia de gol'),
  _Column('Pts', 'points', width: 38, semantic: 'puntos'),
];

const _fullColumns = [
  _Column('J', 'played', semantic: 'jugados'),
  _Column('G', 'won', semantic: 'ganados'),
  _Column('E', 'drawn', semantic: 'empatados'),
  _Column('P', 'lost', semantic: 'perdidos'),
  _Column('GF', 'gf', semantic: 'goles a favor'),
  _Column('GC', 'ga', semantic: 'goles en contra'),
  _Column('DG', 'diff', width: 38, semantic: 'diferencia de gol'),
  _Column('Pts', 'points', width: 38, semantic: 'puntos'),
];

/// Up to 5 chips of 16 px with 3 px gaps, plus a little air.
const double _formWidth = 5 * 16 + 4 * 3 + 6;

const _formColumns = [
  _Column('Forma', 'form', width: _formWidth, semantic: 'forma'),
  _Column('Pts', 'points', width: 38, semantic: 'puntos'),
];

class _Table extends StatelessWidget {
  const _Table({
    required this.entries,
    required this.columns,
    required this.highlightedTeams,
    required this.liveTeamIds,
    this.form,
    super.key,
  });

  final List<_Entry> entries;
  final List<_Column> columns;
  final Map<String, Color> highlightedTeams;
  final Set<String> liveTeamIds;
  final StandingsForm? form;

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
              // Stored rows may carry an alias; Forma is keyed canonically.
              form: form?.results(entries[i].formTeamId) ?? const [],
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

/// G / E / P (Spanish) for WIN / DRAW / LOSS.
const _formLetters = {'WIN': 'G', 'DRAW': 'E', 'LOSS': 'P'};
const _formWords = {'WIN': 'ganado', 'DRAW': 'empatado', 'LOSS': 'perdido'};

class _TeamRow extends StatelessWidget {
  const _TeamRow({
    required this.entry,
    required this.columns,
    required this.accent,
    required this.live,
    required this.divider,
    required this.form,
  });

  final _Entry entry;
  final List<_Column> columns;
  final Color? accent;
  final bool live;
  final bool divider;

  /// Newest first; empty = no data (a dash, never an invented result).
  final List<String> form;

  @override
  Widget build(BuildContext context) {
    final highlighted = accent != null;
    final team = entry.team;
    String? number(_Column column) {
      final value = entry.values[column.key];
      if (value == null) return null;
      return column.key == 'diff' && value > 0 ? '+$value' : '$value';
    }

    String? semantic(_Column column) {
      if (column.key != 'form') {
        final value = number(column);
        return value == null
            ? null
            : '$value ${column.semantic ?? column.label}';
      }
      return form.isEmpty
          ? 'forma sin datos'
          : 'forma ${form.map((r) => _formWords[r]).join(' ')}';
    }

    return Semantics(
      container: true,
      button: entry.teamId.isNotEmpty,
      label: [
        'Posición ${entry.position}',
        entry.name,
        if (live) 'en vivo',
        for (final column in columns) ?semantic(column),
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
              EntityAvatar(team, size: 22),
              const SizedBox(width: 8),
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
                  child: column.key == 'form'
                      ? _FormChips(entry.teamId, form)
                      : Text(
                          number(column) ?? '',
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

/// Up to 5 result chips, newest first; a dash without data.
class _FormChips extends StatelessWidget {
  const _FormChips(this.teamId, this.results);

  final String teamId;
  final List<String> results;

  static const _colors = {
    'WIN': Color(0xFF3FB950),
    'DRAW': Color(0xFF8B949E),
    'LOSS': Color(0xFFE5534B),
  };

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) {
      return Text(
        '—',
        key: ValueKey('standings-form-none-$teamId'),
        textAlign: TextAlign.center,
        style: const TextStyle(color: muted),
      );
    }
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        key: ValueKey('standings-form-$teamId'),
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < results.length && i < 5; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            Container(
              width: 16,
              height: 16,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _colors[results[i]],
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _formLetters[results[i]]!,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ],
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
  const _ViewSwitch({
    required this.views,
    required this.view,
    required this.onChanged,
  });

  final List<StandingsView> views;
  final StandingsView view;
  final ValueChanged<StandingsView> onChanged;

  static const _labels = {
    StandingsView.compact: 'Resumida',
    StandingsView.full: 'Completa',
    StandingsView.form: 'Forma',
  };

  @override
  Widget build(BuildContext context) => Container(
    // Equal segments up to a phone width: three labels always fit at 360 px.
    constraints: BoxConstraints(maxWidth: views.length * 116.0),
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .06),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      children: [
        for (final option in views)
          Expanded(
            child: Semantics(
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
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: option == view ? lime : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    _labels[option]!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: option == view ? Colors.black : muted,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

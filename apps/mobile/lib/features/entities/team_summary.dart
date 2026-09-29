import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';
import 'profile_widgets.dart';
import 'standings.dart';
import 'team_profile.dart' show matchDayLabel;

/// Team / national-team "Resumen" v2 (#156). Order of usefulness: next
/// match, form, table, competitions, news, info. A module without real data
/// is left out (no empty cards); no module is built on data FutBeat does not
/// have (ranking, trophies, leaders, venue).
class TeamSummary extends StatelessWidget {
  const TeamSummary({
    required this.data,
    required this.team,
    required this.matches,
    required this.competitions,
    required this.players,
    this.table,
    this.tableCompetitionId,
    this.tableLabel,
    this.onOpenTab,
    super.key,
  });

  final Snapshot data;
  final Entity team;

  /// The team's matches, oldest first.
  final List<FootballMatch> matches;
  final List<Entity> competitions;
  final int players;

  /// Snapshot holding the table to summarise (the profile context's exact
  /// table, or the profile's own), and that table's competition.
  final Snapshot? table;
  final String? tableCompetitionId;
  final String? tableLabel;

  /// Switches the profile to another tab ('Partidos', 'Tabla', 'Noticias').
  final ValueChanged<String>? onOpenTab;

  @override
  Widget build(BuildContext context) {
    final next = nextTeamMatch(matches, data);
    final form = lastResults(matches, team.id);
    final main = competitions.firstOrNull;
    final tableRows = _tableRows();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (next != null) ...[
          ProfileSectionTitle(next.isLive ? 'En vivo' : 'Partido siguiente'),
          NextMatchCard(match: next, data: data, teamId: team.id),
        ],
        if (form.isNotEmpty) ...[
          _SectionHeader(
            'Últimos partidos',
            action: onOpenTab == null ? null : () => onOpenTab!('Partidos'),
          ),
          TeamFormStrip(results: form, data: data),
        ],
        if (tableRows != null) ...[
          _SectionHeader(
            tableLabel ?? 'Tabla',
            action: onOpenTab == null ? null : () => onOpenTab!('Tabla'),
          ),
          tableRows,
        ],
        if (competitions.isNotEmpty) ...[
          const ProfileSectionTitle('Competiciones'),
          for (final competition in competitions.take(3))
            EntityTile(competition, 'competition'),
        ],
        if (data.news.isNotEmpty) ...[
          _SectionHeader(
            'Noticias',
            action: data.news.length > 2 && onOpenTab != null
                ? () => onOpenTab!('Noticias')
                : null,
          ),
          for (final article in data.news.take(2)) NewsArticleCard(article),
        ],
        const ProfileSectionTitle('Información'),
        ProfileInfoCard([
          if (team.country.isNotEmpty) (Icons.public, 'País', team.country),
          if (main != null)
            (Icons.emoji_events_outlined, 'Competición principal', main.name),
          if (players > 0) (Icons.groups_outlined, 'Jugadores', '$players'),
        ]),
      ],
    );
  }

  /// The team's own group, around its position (at most 5 rows); null when
  /// the table cannot be shown correctly (never a mixed table).
  Widget? _tableRows() {
    final source = table;
    final competitionId = tableCompetitionId;
    if (source == null || competitionId == null) return null;
    final groups = standingsGroups(
      standingsTableFor(source, competitionId),
      source,
      focusTeamIds: {team.id},
    );
    final holding = groups
        ?.where((g) => g.rows.any((row) => row['teamId'] == team.id))
        .toList();
    // Exactly one group: never pick one of several phases silently.
    if (holding == null || holding.length != 1) return null;
    final group = holding.single;
    final rows = group.rows;
    final at = rows.indexWhere((row) => row['teamId'] == team.id);
    final start = (at - 2).clamp(0, (rows.length - 5).clamp(0, rows.length));
    return SummaryTable(
      data: source,
      rows: rows.skip(start).take(5).toList(),
      teamId: team.id,
      title: group.label,
    );
  }
}

/// The match for "Partido siguiente": live now (a LIVE kickoff older than
/// 4 h is stale, never "now") or else the soonest upcoming one; only matches
/// whose two teams can be shown.
FootballMatch? nextTeamMatch(List<FootballMatch> matches, Snapshot data) {
  final now = costaRicaNow();
  bool shown(FootballMatch m) =>
      data.team(m.homeId) != null && data.team(m.awayId) != null;
  final live = matches.where(
    (m) =>
        m.isLive &&
        shown(m) &&
        now.difference(m.startTime) < const Duration(hours: 4),
  );
  if (live.isNotEmpty) return live.first;
  return matches.where((m) => m.isUpcoming && shown(m)).firstOrNull;
}

/// The team's result in a final with a score: 'G', 'E' or 'P' (a shootout
/// counts as 'E': no shootout data); null otherwise or when the team is on
/// neither side.
String? teamResult(FootballMatch match, String teamId) {
  if (!match.isFinished) return null;
  if (match.homeId != teamId && match.awayId != teamId) return null;
  final score = match.json['score'];
  if (score is! Map) return null;
  final home = score['home'], away = score['away'];
  if (home is! num || away is! num) return null;
  final mine = match.homeId == teamId ? home : away;
  final theirs = match.homeId == teamId ? away : home;
  return mine > theirs
      ? 'G'
      : mine == theirs
      ? 'E'
      : 'P';
}

const _resultWords = {'G': 'Ganó', 'E': 'Empató', 'P': 'Perdió'};

/// Last (up to 5) finished matches with a score, newest first, as the
/// team's result.
List<({FootballMatch match, String result})> lastResults(
  List<FootballMatch> matches,
  String teamId, {
  int limit = 5,
}) {
  final finished = matches.where((m) => m.isFinished).toList()
    ..sort((a, b) => b.startTime.compareTo(a.startTime));
  final out = <({FootballMatch match, String result})>[];
  for (final match in finished) {
    final result = teamResult(match, teamId);
    if (result == null) continue;
    out.add((match: match, result: result));
    if (out.length == limit) break;
  }
  return out;
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, {this.action});

  final String title;
  final VoidCallback? action;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: ProfileSectionTitle(title)),
      if (action != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: TextButton(
            onPressed: action,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              foregroundColor: lime,
            ),
            child: const Text('Ver todo'),
          ),
        ),
    ],
  );
}

/// "Partido siguiente": competition + day, both sides, kickoff or live
/// score. Tapping opens the match.
class NextMatchCard extends StatelessWidget {
  const NextMatchCard({
    required this.match,
    required this.data,
    required this.teamId,
    super.key,
  });

  final FootballMatch match;
  final Snapshot data;
  final String teamId;

  @override
  Widget build(BuildContext context) {
    final home = data.team(match.homeId);
    final away = data.team(match.awayId);
    final competition = data.competition(match.competitionId);
    if (home == null || away == null) return const SizedBox.shrink();
    final day = _dayLabel(match.startTime);
    return Semantics(
      container: true,
      label: [
        if (competition != null) competition.name,
        if (match.isLive) 'En vivo ${match.score}' else day,
        '${home.name} contra ${away.name}',
        if (!match.isLive) localTime(context, match.startTime),
      ].join(', '),
      child: Material(
        key: const ValueKey('team-next-match'),
        color: Colors.white.withValues(alpha: .04),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push(
            '/match/${match.id}',
            extra: data.forMatch(match.id),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              children: [
                Text(
                  [
                    if (competition != null) competition.name,
                    if (!match.isLive) day,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _Side(home, highlighted: home.id == teamId),
                    ),
                    SizedBox(
                      width: 92,
                      child: Column(
                        children: [
                          Text(
                            match.isLive
                                ? match.score
                                : localTime(context, match.startTime),
                            style: TextStyle(
                              fontSize: match.isLive ? 26 : 22,
                              fontWeight: FontWeight.w900,
                              color: match.isLive ? lime : null,
                            ),
                          ),
                          if (match.isLive) ...[
                            const SizedBox(height: 2),
                            Text(
                              match.statusLabel,
                              style: const TextStyle(color: lime, fontSize: 11),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Expanded(
                      child: _Side(away, highlighted: away.id == teamId),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _dayLabel(DateTime start) {
    final today = costaRicaNow();
    final date = DateTime.utc(start.year, start.month, start.day);
    final days = date.difference(
      DateTime.utc(today.year, today.month, today.day),
    );
    return switch (days.inDays) {
      0 => 'Hoy',
      1 => 'Mañana',
      _ => matchDayLabel(start),
    };
  }
}

class _Side extends StatelessWidget {
  const _Side(this.team, {required this.highlighted});

  final Entity team;
  final bool highlighted;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      EntityAvatar(team, size: 40),
      const SizedBox(height: 6),
      Text(
        team.name,
        maxLines: 2,
        textAlign: TextAlign.center,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          fontWeight: highlighted ? FontWeight.w800 : FontWeight.w600,
        ),
      ),
    ],
  );
}

/// Last results as G / E / P chips with the score (home - away), newest
/// first. Tapping a chip opens that match.
class TeamFormStrip extends StatelessWidget {
  const TeamFormStrip({required this.results, required this.data, super.key});

  final List<({FootballMatch match, String result})> results;
  final Snapshot data;

  static Color colorOf(String result) => switch (result) {
    'G' => const Color(0xFF2FBF71),
    'E' => const Color(0xFF8A94A6),
    _ => const Color(0xFFE5484D),
  };

  @override
  Widget build(BuildContext context) => Row(
    key: const ValueKey('team-form'),
    children: [
      for (final item in results)
        Expanded(
          child: Semantics(
            label:
                '${_resultWords[item.result]} ${item.match.score}, '
                '${data.team(item.match.homeId)?.name ?? ''} contra '
                '${data.team(item.match.awayId)?.name ?? ''}',
            button: true,
            excludeSemantics: true,
            child: InkWell(
              key: ValueKey('team-form-${item.match.id}'),
              borderRadius: BorderRadius.circular(10),
              onTap: () => context.push(
                '/match/${item.match.id}',
                extra: data.forMatch(item.match.id),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: colorOf(item.result),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        item.result,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      item.match.score,
                      style: const TextStyle(fontSize: 11, color: muted),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

/// A few rows of the team's group: Pos, Equipo, J, DG, Pts.
class SummaryTable extends StatelessWidget {
  const SummaryTable({
    required this.data,
    required this.rows,
    required this.teamId,
    this.title,
    super.key,
  });

  final Snapshot data;
  final List<Json> rows;
  final String teamId;
  final String? title;

  @override
  Widget build(BuildContext context) {
    Widget cell(String text, {bool bold = false, double width = 34}) =>
        SizedBox(
          width: width,
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
            ),
          ),
        );
    return Container(
      key: const ValueKey('team-summary-table'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .03),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: profileCardBorder),
      ),
      child: Column(
        children: [
          if (title != null && title!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  title!,
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: DefaultTextStyle.merge(
              style: const TextStyle(color: muted),
              child: Row(
                children: [
                  cell('#', width: 28),
                  const Expanded(
                    child: Text('Equipo', style: TextStyle(fontSize: 11)),
                  ),
                  cell('J'),
                  cell('DG'),
                  cell('Pts'),
                ],
              ),
            ),
          ),
          for (final row in rows)
            Container(
              key: ValueKey('team-summary-row-${row['teamId']}'),
              color: row['teamId'] == teamId
                  ? lime.withValues(alpha: .10)
                  : null,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  cell('${row['position'] ?? ''}', width: 28),
                  Expanded(
                    child: Row(
                      children: [
                        if (data.team('${row['teamId']}') case final team?)
                          EntityAvatar(team, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            data.team('${row['teamId']}')?.name ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: row['teamId'] == teamId
                                  ? FontWeight.w800
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  cell('${row['played'] ?? ''}'),
                  cell(_goalDifference(row)),
                  cell('${row['points'] ?? ''}', bold: true),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _goalDifference(Json row) {
    final gf = row['gf'], ga = row['ga'];
    if (gf is! num || ga is! num) return '';
    final diff = gf - ga;
    return diff > 0 ? '+$diff' : '$diff';
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models.dart';
import '../../core/profile_context.dart';
import '../../core/providers.dart';
import '../../core/team_matches.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';
import 'profile_widgets.dart';
import 'team_profile.dart' show matchDayLabel;

/// Team profile "Partidos": En vivo (only when something is in play),
/// Próximos (next first) and Resultados (latest first) across every
/// competition, paginated by the server's team matches
/// read model. The profile's own matches render immediately (cache-first)
/// until the first page arrives; a failed page never blocks the tab.
/// With a profile context (#161) the list can be narrowed to that
/// competition + season ("Todos" stays the default).
class TeamMatchesTab extends ConsumerStatefulWidget {
  const TeamMatchesTab({
    required this.team,
    required this.data,
    required this.matches,
    this.contextOption,
    super.key,
  });

  final Entity team;
  final Snapshot data;
  final List<FootballMatch> matches;
  final ProfileContextOption? contextOption;

  @override
  ConsumerState<TeamMatchesTab> createState() => _TeamMatchesTabState();
}

class _TeamMatchesTabState extends ConsumerState<TeamMatchesTab> {
  final _pages = {
    for (final bucket in TeamMatchesBucket.values) bucket: <TeamMatchesPage>[],
  };
  final _loading = <TeamMatchesBucket>{};
  final _failed = <TeamMatchesBucket>{};
  ApiRepository? _api;

  /// Only the profile context's competition + season.
  bool _filtered = false;

  /// Bumped on every filter change: answers of an older list are dropped.
  int _generation = 0;

  ProfileContextOption? get _filter => _filtered ? widget.contextOption : null;

  @override
  void didUpdateWidget(TeamMatchesTab old) {
    super.didUpdateWidget(old);
    if (_filtered && old.contextOption?.key != widget.contextOption?.key) {
      _reset(filtered: widget.contextOption != null);
    }
  }

  void _reset({required bool filtered}) {
    setState(() {
      _filtered = filtered;
      _generation++;
      for (final pages in _pages.values) {
        pages.clear();
      }
      _loading.clear();
      _failed.clear();
    });
    for (final bucket in TeamMatchesBucket.values) {
      _load(bucket);
    }
  }

  @override
  void initState() {
    super.initState();
    final repository = ref.read(repositoryProvider);
    if (repository is ApiRepository) {
      _api = repository;
      for (final bucket in TeamMatchesBucket.values) {
        _load(bucket);
      }
    }
  }

  Future<void> _load(TeamMatchesBucket bucket) async {
    final api = _api;
    final pages = _pages[bucket]!;
    if (api == null || _loading.contains(bucket)) return;
    if (pages.isNotEmpty && !pages.last.hasMore) return;
    final generation = _generation;
    final filter = _filter;
    setState(() {
      _loading.add(bucket);
      _failed.remove(bucket);
    });
    try {
      final page = await api.loadTeamMatches(
        widget.team.id,
        bucket.wire,
        cursor: pages.lastOrNull?.nextCursor,
        competitionId: filter?.competitionId,
        season: filter?.seasonParam,
      );
      if (mounted && generation == _generation) {
        setState(() => pages.add(page));
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _failed.add(bucket));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading.remove(bucket));
      }
    }
  }

  bool _inFilter(FootballMatch match) {
    final filter = _filter;
    return filter == null ||
        (match.competitionId == filter.competitionId &&
            normalizeSeasonKey(match.season) == filter.seasonKey);
  }

  List<ProfileMatch> _items(TeamMatchesBucket bucket) {
    final pages = _pages[bucket]!;
    return orderedProfileMatches(
      bucket,
      pages.isEmpty
          ? [
              for (final m in widget.matches)
                if (_inFilter(m)) (match: m, data: widget.data),
            ]
          : [
              for (final page in pages)
                for (final m in page.data.matches) (match: m, data: page.data),
            ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final option = widget.contextOption;
    return ProfileTabList('partidos', [
      if (widget.data.demo) const DemoNotice(),
      if (option != null && _api != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                key: const ValueKey('team-matches-filter-all'),
                label: const Text('Todos'),
                selected: !_filtered,
                onSelected: (_) {
                  if (_filtered) _reset(filtered: false);
                },
              ),
              ChoiceChip(
                key: const ValueKey('team-matches-filter-context'),
                label: Text(option.label),
                selected: _filtered,
                onSelected: (_) {
                  if (!_filtered) _reset(filtered: true);
                },
              ),
            ],
          ),
        ),
      ..._section(TeamMatchesBucket.live, 'En vivo', null),
      ..._section(
        TeamMatchesBucket.upcoming,
        'Próximos',
        'Sin partidos próximos',
      ),
      ..._section(TeamMatchesBucket.results, 'Resultados', 'Sin resultados'),
    ]);
  }

  /// Empty copy from the team's central coverage: still arriving and "no
  /// source" are never shown as a confirmed empty list.
  String _emptyCopy(TeamMatchesBucket bucket, String fallback) {
    return switch (_pages[bucket]!.lastOrNull?.coverageState) {
      'PENDING' => 'Cargando partidos',
      'UNAVAILABLE' => 'Partidos no disponibles',
      _ => fallback,
    };
  }

  /// A null [empty] hides the whole section while it has no matches.
  List<Widget> _section(TeamMatchesBucket bucket, String title, String? empty) {
    final items = _items(bucket);
    final pages = _pages[bucket]!;
    final loading = _loading.contains(bucket);
    final failed = _failed.contains(bucket);
    final more = pages.isNotEmpty && pages.last.hasMore;
    if (empty == null && items.isEmpty) return const [];
    return [
      ProfileSectionTitle(title),
      if (items.isEmpty && !loading)
        InlineEmpty(
          Icons.event_busy_outlined,
          _emptyCopy(bucket, empty!),
          key: ValueKey('team-matches-empty-${bucket.wire}'),
        )
      else
        for (final item in items) _DatedMatch(item, teamId: widget.team.id),
      if (loading && (items.isEmpty || more))
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Center(
            child: SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        )
      else if (more || failed)
        Center(
          child: TextButton(
            key: ValueKey('team-matches-more-${bucket.wire}'),
            onPressed: () => _load(bucket),
            child: Text(failed ? 'Reintentar' : 'Ver más'),
          ),
        ),
    ];
  }
}

class _DatedMatch extends StatelessWidget {
  const _DatedMatch(this.item, {required this.teamId});

  final ProfileMatch item;
  final String teamId;

  @override
  Widget build(BuildContext context) =>
      ProfileMatchRow(match: item.match, data: item.data, teamId: teamId);
}

/// One compact row of the profile "Partidos" (#157): date (+ competition),
/// both sides, score or kickoff, and the team's result when final.
class ProfileMatchRow extends StatelessWidget {
  const ProfileMatchRow({
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
    if (home == null || away == null) return const SizedBox.shrink();
    final competition = data.competition(match.competitionId);
    final result = _result();
    final center = match.isLive
        ? match.score
        : match.showKickoff
        ? localTime(context, match.startTime)
        : match.score;
    Widget side(Entity team, {required bool end}) => Expanded(
      child: Row(
        mainAxisAlignment: end
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          if (!end) ...[EntityAvatar(team, size: 20), const SizedBox(width: 6)],
          Flexible(
            child: Text(
              team.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: end ? TextAlign.end : TextAlign.start,
              style: TextStyle(
                fontSize: 13,
                fontWeight: team.id == teamId
                    ? FontWeight.w800
                    : FontWeight.w500,
              ),
            ),
          ),
          if (end) ...[const SizedBox(width: 6), EntityAvatar(team, size: 20)],
        ],
      ),
    );
    return InkWell(
      key: ValueKey('profile-match-${match.id}'),
      borderRadius: BorderRadius.circular(12),
      onTap: () =>
          context.push('/match/${match.id}', extra: data.forMatch(match.id)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              [
                '${matchDayLabel(match.startTime)} ${match.startTime.year}',
                if (competition != null) competition.name,
                // Kickoff passed, no final yet: never presented as upcoming.
                if (match.isAwaitingUpdate) 'Por confirmar',
                if (match.isLive) match.statusLabel,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: match.isLive ? lime : muted,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                side(home, end: false),
                Container(
                  width: 64,
                  alignment: Alignment.center,
                  child: Text(
                    center,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: match.isLive ? lime : null,
                    ),
                  ),
                ),
                side(away, end: true),
                const SizedBox(width: 8),
                SizedBox(
                  width: 22,
                  child: result == null
                      ? null
                      : Container(
                          key: ValueKey('profile-match-result-${match.id}'),
                          height: 20,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: _color(result),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            result,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String? _result() {
    if (!match.isFinished) return null;
    final score = match.json['score'];
    if (score is! Map) return null;
    final home = score['home'], away = score['away'];
    if (home is! num || away is! num) return null;
    if (match.homeId != teamId && match.awayId != teamId) return null;
    final mine = match.homeId == teamId ? home : away;
    final theirs = match.homeId == teamId ? away : home;
    return mine > theirs
        ? 'G'
        : mine == theirs
        ? 'E'
        : 'P';
  }

  static Color _color(String result) => switch (result) {
    'G' => const Color(0xFF2FBF71),
    'E' => const Color(0xFF8A94A6),
    _ => const Color(0xFFE5484D),
  };
}

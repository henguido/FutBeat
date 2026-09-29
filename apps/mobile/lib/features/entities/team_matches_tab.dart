import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/team_matches.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';
import '../matches/matches_screen.dart';
import 'profile_widgets.dart';
import 'team_profile.dart' show matchDayLabel;

/// Team profile "Partidos": En vivo (only when something is in play),
/// Próximos (next first) and Resultados (latest first) across every
/// competition, paginated by the server's team matches
/// read model. The profile's own matches render immediately (cache-first)
/// until the first page arrives; a failed page never blocks the tab.
class TeamMatchesTab extends ConsumerStatefulWidget {
  const TeamMatchesTab({
    required this.team,
    required this.data,
    required this.matches,
    super.key,
  });

  final Entity team;
  final Snapshot data;
  final List<FootballMatch> matches;

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
    setState(() {
      _loading.add(bucket);
      _failed.remove(bucket);
    });
    try {
      final page = await api.loadTeamMatches(
        widget.team.id,
        bucket.wire,
        cursor: pages.lastOrNull?.nextCursor,
      );
      if (mounted) setState(() => pages.add(page));
    } catch (_) {
      if (mounted) setState(() => _failed.add(bucket));
    } finally {
      if (mounted) setState(() => _loading.remove(bucket));
    }
  }

  List<ProfileMatch> _items(TeamMatchesBucket bucket) {
    final pages = _pages[bucket]!;
    return orderedProfileMatches(
      bucket,
      pages.isEmpty
          ? [for (final m in widget.matches) (match: m, data: widget.data)]
          : [
              for (final page in pages)
                for (final m in page.data.matches) (match: m, data: page.data),
            ],
    );
  }

  @override
  Widget build(BuildContext context) => ProfileTabList('partidos', [
    if (widget.data.demo) const DemoNotice(),
    ..._section(TeamMatchesBucket.live, 'En vivo', null),
    ..._section(
      TeamMatchesBucket.upcoming,
      'Próximos',
      'Sin partidos próximos',
    ),
    ..._section(TeamMatchesBucket.results, 'Resultados', 'Sin resultados'),
  ]);

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
        InlineEmpty(Icons.event_busy_outlined, empty!)
      else
        for (final item in items) _DatedMatch(item),
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
  const _DatedMatch(this.item);

  final ProfileMatch item;

  @override
  Widget build(BuildContext context) {
    final match = item.match;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 4),
            child: Text(
              [
                '${matchDayLabel(match.startTime)} · ${match.startTime.year}',
                // Kickoff passed, no final yet: never presented as upcoming.
                if (match.isAwaitingUpdate) 'Por confirmar',
              ].join(' · '),
              style: const TextStyle(color: muted, fontSize: 12),
            ),
          ),
          MatchCard(match, item.data),
        ],
      ),
    );
  }
}

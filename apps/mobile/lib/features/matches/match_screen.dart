import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/interests.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';
import '../entities/standings.dart';
import 'match_preview_sections.dart';

const _headerTop = Color(0xFF1B2B31);
const _headerBottom = Color(0xFF0F181C);
const _cardBorder = Color(0xFF2B373D);
const awaySideColor = Color(0xFF4FC3F7);

/// Bounded refreshes while the server hydrates missing lineup photos.
/// Same cadence as EntityScreen's profileEnrichmentRetryDelays.
const _lineupEnrichmentRetryDelays = [
  Duration(seconds: 6),
  Duration(seconds: 12),
];

/// Bounded context refreshes while the exact competition+season table is
/// being fetched on demand ("Cargando tabla…" is shown during these).
const standingsRetryDelays = [
  Duration(seconds: 8),
  Duration(seconds: 20),
  Duration(seconds: 40),
];

/// After the visible refreshes: a few slow, silent revalidations (no
/// spinner) so a durable server demand answered later still appears in
/// place. Finite: no endless polling.
const standingsSilentRetryDelays = [
  Duration(seconds: 90),
  Duration(seconds: 180),
];

const _standingsSchedule = [
  ...standingsRetryDelays,
  ...standingsSilentRetryDelays,
];

/// #120: while the shown match is LIVE but its live data went silent (no
/// realtime for 15 min), re-read the canonical context a few times so a
/// final recorded server-side replaces "EN VIVO". FutBeat API only; finite.
const staleLiveRefreshDelays = [
  Duration(seconds: 5),
  Duration(seconds: 30),
  Duration(seconds: 60),
  Duration(seconds: 120),
  Duration(seconds: 300),
];

/// #132: detail hydration may keep doing bounded read-only rechecks for the
/// cron fallback, but the Match Center must not look busy for that whole
/// period. After this window the same rechecks continue silently.
const matchDetailRefreshIndicatorDuration = Duration(seconds: 8);

class MatchScreen extends ConsumerStatefulWidget {
  const MatchScreen({super.key, required this.id, this.initialData});

  final String id;
  final Snapshot? initialData;

  @override
  ConsumerState<MatchScreen> createState() => _MatchScreenState();
}

class _MatchScreenState extends ConsumerState<MatchScreen>
    with TickerProviderStateMixin {
  final Set<String> _recordedTeamInterests = {};
  late TabController _tabs;
  Timer? _lineupEnrichmentRetry;
  int _lineupEnrichmentAttempts = 0;
  Timer? _standingsRetry;
  int _standingsAttempts = 0;
  bool _standingsManualRetry = false;
  Timer? _staleLiveRefresh;
  int _staleLiveAttempts = 0;
  Timer? _detailRefreshIndicatorTimer;
  bool _detailRefreshIndicatorExpired = false;

  @override
  void initState() {
    super.initState();
    // Stable structure: Tabla always exists (its content reports the state),
    // so tabs never appear/disappear while data arrives.
    _tabs = TabController(length: 5, vsync: this);
    _detailRefreshIndicatorTimer = Timer(
      matchDetailRefreshIndicatorDuration,
      () {
        if (!mounted) return;
        setState(() => _detailRefreshIndicatorExpired = true);
      },
    );
    Future.microtask(() => recordTemporaryInterest(ref, 'match', widget.id));
  }

  void _scheduleLineupEnrichmentRefresh() {
    if (_lineupEnrichmentRetry != null ||
        _lineupEnrichmentAttempts >= _lineupEnrichmentRetryDelays.length) {
      return;
    }
    _lineupEnrichmentRetry = Timer(
      _lineupEnrichmentRetryDelays[_lineupEnrichmentAttempts],
      () {
        if (!mounted) return;
        setState(() {
          _lineupEnrichmentAttempts++;
          _lineupEnrichmentRetry = null;
        });
        ref.invalidate(matchDetailProvider(widget.id));
      },
    );
  }

  void _scheduleStandingsRefresh() {
    if (_standingsRetry != null ||
        _standingsAttempts >= _standingsSchedule.length) {
      return;
    }
    _standingsRetry = Timer(_standingsSchedule[_standingsAttempts], () {
      if (!mounted) return;
      setState(() {
        _standingsAttempts++;
        _standingsRetry = null;
      });
      ref.invalidate(matchContextSnapshotProvider(widget.id));
    });
  }

  void _watchStaleLive(Snapshot merged) {
    if (merged.match(widget.id)?.liveDataStale != true) {
      _staleLiveRefresh?.cancel();
      _staleLiveRefresh = null;
      _staleLiveAttempts = 0;
      return;
    }
    if (_staleLiveRefresh != null ||
        _staleLiveAttempts >= staleLiveRefreshDelays.length) {
      return;
    }
    _staleLiveRefresh = Timer(staleLiveRefreshDelays[_staleLiveAttempts], () {
      if (!mounted) return;
      _staleLiveAttempts++;
      _staleLiveRefresh = null;
      ref.invalidate(matchContextSnapshotProvider(widget.id));
    });
  }

  /// "Reintentar": one more read of the same context in this screen. The
  /// server deduplicates the demand, so repeated taps never add provider
  /// calls; the button is disabled while the read is in flight.
  Future<void> _retryStandings() async {
    if (_standingsManualRetry) return;
    setState(() => _standingsManualRetry = true);
    ref.invalidate(matchContextSnapshotProvider(widget.id));
    try {
      await ref.read(matchContextSnapshotProvider(widget.id).future);
    } catch (_) {
      // Keep the settled state; the user can try again.
    }
    if (mounted) setState(() => _standingsManualRetry = false);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _lineupEnrichmentRetry?.cancel();
    _standingsRetry?.cancel();
    _staleLiveRefresh?.cancel();
    _detailRefreshIndicatorTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final updates =
        ref.watch(liveMatchUpdatesProvider).asData?.value ??
        const <String, LiveMatchUpdate>{};
    ref.listen(matchDetailProvider(widget.id), (_, next) {
      // Ignore the refresh-in-progress state (it still carries old data).
      if (!next.isLoading &&
          next.asData?.value.lineupEnrichmentPending == true) {
        _scheduleLineupEnrichmentRefresh();
      }
    });
    final watchesContext =
        ref.watch(repositoryProvider) is ApiRepository ||
        widget.initialData == null;
    if (watchesContext) {
      ref.listen(matchContextSnapshotProvider(widget.id), (_, next) {
        if (next.isLoading || next.value == null) return;
        if (next.value!.standingsPending) {
          _scheduleStandingsRefresh();
        } else {
          // Answered (or settled server-side): no further revalidation.
          _standingsRetry?.cancel();
          _standingsRetry = null;
        }
      });
    }
    // `.value` keeps the current context visible while a refresh is loading
    // (no flash back to the list snapshot, tabs and scroll untouched).
    final refreshed = watchesContext
        ? ref.watch(matchContextSnapshotProvider(widget.id)).value
        : null;
    final initialData = refreshed ?? widget.initialData;
    if (initialData != null) {
      final merged = initialData.withLiveUpdates(updates);
      if (watchesContext) _watchStaleLive(merged);
      return _buildMatchCenter(merged);
    }

    return ref
        .watch(matchContextSnapshotProvider(widget.id))
        .when(
          loading: () => Scaffold(
            appBar: AppBar(title: const Text('Match Center')),
            body: const Center(child: CircularProgressIndicator()),
          ),
          error: (_, stack) => Scaffold(
            appBar: AppBar(title: const Text('Match Center')),
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const EmptyState(
                    'No pudimos cargar este partido',
                    'Revisa tu conexión e intenta nuevamente.',
                    icon: Icons.cloud_off,
                  ),
                  FilledButton(
                    onPressed: () async {
                      ref.invalidate(matchContextSnapshotProvider(widget.id));
                      try {
                        await ref.read(
                          matchContextSnapshotProvider(widget.id).future,
                        );
                      } catch (_) {
                        // Keep the recoverable error state visible.
                      }
                    },
                    child: const Text('Reintentar'),
                  ),
                ],
              ),
            ),
          ),
          data: (data) {
            final merged = data.withLiveUpdates(updates);
            _watchStaleLive(merged);
            return _buildMatchCenter(merged);
          },
        );
  }

  Widget _buildMatchCenter(Snapshot data) {
    final match = data.match(widget.id);
    if (match == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Partido')),
        body: const EmptyState(
          'Partido no encontrado',
          'Vuelve a Partidos para consultar los encuentros disponibles.',
        ),
      );
    }

    for (final teamId in [match.homeId, match.awayId]) {
      if (_recordedTeamInterests.add(teamId)) {
        Future.microtask(() => recordTemporaryInterest(ref, 'team', teamId));
      }
    }

    final competition = data.competition(match.competitionId);
    if (competition == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Partido')),
        body: const EmptyState(
          'Competición no disponible',
          'Vuelve a Partidos e intenta nuevamente.',
        ),
      );
    }

    final detail =
        ref.watch(matchDetailProvider(widget.id)).asData?.value ??
        MatchDetail.waiting(widget.id);
    final venue = detail.stadium ?? match.json['venue']?.toString() ?? '';
    final home = data.team(match.homeId)!;
    final away = data.team(match.awayId)!;
    final hasStats =
        detail.statistics.isNotEmpty || match.statistics.isNotEmpty;
    // Recent form + head-to-head: a separate read, never blocking the header
    // or the tabs, failing on its own, read once per open.
    final preview = ref.watch(matchPreviewProvider(widget.id));
    // Before kickoff an empty events card adds nothing; real events, a
    // started/finished match or a pending detail of a started one show it.
    final showEvents =
        !match.showKickoff ||
        (match.isAwaitingUpdate && detail.pending) ||
        mergedMatchTimeline(match, detail).isNotEmpty;
    final previewSections = [
      const _SectionTitle('Forma reciente'),
      RecentFormSection(preview: preview, data: data, match: match),
      StandingsSnapshotCard(data: data, match: match),
    ];

    // Bounded: once the retries are spent a pending table settles into a
    // stable state (no endless spinner).
    final standingsRefreshing =
        data.standingsPending &&
        _standingsAttempts < standingsRetryDelays.length;
    final refreshing =
        (detail.pending && !_detailRefreshIndicatorExpired) ||
        standingsRefreshing;

    final tabBar = TabBar(
      controller: _tabs,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      labelPadding: const EdgeInsets.symmetric(horizontal: 14),
      labelColor: Colors.white,
      unselectedLabelColor: muted,
      labelStyle: const TextStyle(
        fontFamily: 'FutBeatRoboto',
        fontSize: 14,
        fontWeight: FontWeight.w800,
      ),
      unselectedLabelStyle: const TextStyle(
        fontFamily: 'FutBeatRoboto',
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
      indicatorSize: TabBarIndicatorSize.label,
      indicator: const UnderlineTabIndicator(
        borderSide: BorderSide(color: lime, width: 3),
        borderRadius: BorderRadius.vertical(top: Radius.circular(3)),
      ),
      dividerColor: Colors.transparent,
      tabs: [
        const Tab(text: 'Previa', height: 42),
        const Tab(text: 'Estadísticas', height: 42),
        const Tab(text: 'Alineación', height: 42),
        const Tab(text: 'Tabla', height: 42),
        const Tab(text: 'Cara a cara', height: 42),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Match Center'),
        backgroundColor: _headerTop,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        actions: [FollowButton('match', widget.id)],
      ),
      body: NestedScrollView(
        headerSliverBuilder: (context, _) => [
          SliverToBoxAdapter(
            child: MatchHero(
              data: data,
              match: match,
              competition: competition,
              detail: detail,
              venue: venue,
            ),
          ),
          SliverOverlapAbsorber(
            handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
            sliver: SliverPersistentHeader(
              pinned: true,
              delegate: _TabBarHeader(tabBar, refreshing: refreshing),
            ),
          ),
        ],
        body: TabBarView(
          controller: _tabs,
          children: [
            _MatchTabList('previa', [
              if (data.demo) const DemoNotice(),
              // Before kickoff the match facts lead; afterwards the story.
              if (match.showKickoff) ...[
                const _SectionTitle('Información del partido'),
                MatchInfoCard(
                  match: match,
                  competition: competition,
                  detail: detail,
                  venue: venue,
                ),
                ...previewSections,
              ],
              if (detail.videos.isNotEmpty) ...[
                const _SectionTitle('Resumen oficial'),
                PostMatchVideos(detail),
              ],
              if (showEvents) ...[
                const _SectionTitle('Eventos del partido'),
                MatchTimeline(data, match, detail),
              ],
              if (!match.showKickoff && detail.topRated().isNotEmpty) ...[
                _SectionTitle(_topRatedTitle(match, detail)),
                if (match.isLive)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Provisional',
                      style: TextStyle(
                        color: muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                TopRatedCard(
                  key: const ValueKey('top-rated-card'),
                  topRated: detail.topRated(),
                  home: home,
                  away: away,
                ),
                const _SectionTitle('Mejor puntuado por equipo'),
                if (match.isLive)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Provisional',
                      style: TextStyle(
                        color: muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                TeamTopRatedCard(
                  key: const ValueKey('team-top-rated-card'),
                  best: detail.bestRatedBySide(),
                  home: home,
                  away: away,
                ),
              ],
              if (hasStats) ...[
                const _SectionTitle('Estadísticas clave'),
                Statistics(match, detail: detail, limit: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => _tabs.animateTo(1),
                    icon: const Icon(Icons.bar_chart_rounded, size: 18),
                    label: const Text('Ver todas las estadísticas'),
                  ),
                ),
              ],
              if (!match.showKickoff) ...[
                const _SectionTitle('Información del partido'),
                MatchInfoCard(
                  match: match,
                  competition: competition,
                  detail: detail,
                  venue: venue,
                ),
                ...previewSections,
              ],
            ]),
            _MatchTabList('estadisticas', [
              if (data.demo) const DemoNotice(),
              _StatsLegend(home: home, away: away),
              const SizedBox(height: 12),
              Statistics(match, detail: detail),
            ]),
            _MatchTabList('alineacion', [
              if (data.demo) const DemoNotice(),
              Lineups(data, match, detail),
            ]),
            _MatchTabList('tabla', [
              if (data.demo) const DemoNotice(),
              MatchStandingsTab(
                data,
                match.competitionId,
                homeTeamId: match.homeId,
                awayTeamId: match.awayId,
                refreshing: standingsRefreshing || _standingsManualRetry,
                onRetry: _retryStandings,
              ),
            ]),
            _MatchTabList('cara-a-cara', [
              if (data.demo) const DemoNotice(),
              HeadToHeadTab(
                preview: preview,
                data: data,
                match: match,
                onRetry: () => ref.invalidate(matchPreviewProvider(widget.id)),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

class _TabBarHeader extends SliverPersistentHeaderDelegate {
  _TabBarHeader(this.tabBar, {this.refreshing = false});

  final TabBar tabBar;

  /// Discreet signal while missing data is being fetched.
  final bool refreshing;

  @override
  double get minExtent => tabBar.preferredSize.height + 1;

  @override
  double get maxExtent => tabBar.preferredSize.height + 1;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => DecoratedBox(
    decoration: const BoxDecoration(
      color: _headerBottom,
      border: Border(bottom: BorderSide(color: _cardBorder)),
    ),
    child: Stack(
      children: [
        Align(alignment: Alignment.centerLeft, child: tabBar),
        if (refreshing)
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: LinearProgressIndicator(
              key: ValueKey('match-refreshing'),
              minHeight: 2,
              backgroundColor: Colors.transparent,
            ),
          ),
      ],
    ),
  );

  @override
  bool shouldRebuild(covariant _TabBarHeader oldDelegate) =>
      oldDelegate.tabBar != tabBar || oldDelegate.refreshing != refreshing;
}

/// One scrollable tab body that cooperates with the collapsible header.
class _MatchTabList extends StatelessWidget {
  const _MatchTabList(this.storageKey, this.children);

  final String storageKey;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => CustomScrollView(
    key: PageStorageKey<String>(storageKey),
    slivers: [
      SliverOverlapInjector(
        handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
        sliver: SliverList(delegate: SliverChildListDelegate(children)),
      ),
    ],
  );
}

/// #99: "Jugador del partido" only once the match is over and a single
/// player stands out (no tie at the top); a live match shows a provisional
/// leader; otherwise a calmer "Mejores puntuados" plural.
String _topRatedTitle(FootballMatch match, MatchDetail detail) {
  if (match.isFinished && detail.playerOfTheMatch != null) {
    return 'Jugador del partido';
  }
  if (match.isLive) return 'Mejor puntuado';
  return 'Mejores puntuados';
}

class TopRatedCard extends StatelessWidget {
  const TopRatedCard({
    required this.topRated,
    required this.home,
    required this.away,
    super.key,
  });

  final List<({Json player, String side})> topRated;
  final Entity home;
  final Entity away;

  String _teamName(String side) => side == 'home' ? home.name : away.name;

  @override
  Widget build(BuildContext context) {
    if (topRated.isEmpty) return const SizedBox.shrink();
    final top = topRated.first;
    final rest = topRated.skip(1).toList();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TopRatedEntry(
            entry: top,
            teamName: _teamName(top.side),
            prominent: true,
          ),
          for (var i = 0; i < rest.length; i++) ...[
            const SizedBox(height: 8),
            _TopRatedEntry(
              key: ValueKey('top-rated-${i + 1}'),
              entry: rest[i],
              teamName: _teamName(rest[i].side),
            ),
          ],
        ],
      ),
    );
  }
}

/// #99 best rated player of each side, side by side. A tie at a side's
/// top shows the tied players (max 2) as equals; a side without ratings
/// stays empty (no placeholder).
class TeamTopRatedCard extends StatelessWidget {
  const TeamTopRatedCard({
    required this.best,
    required this.home,
    required this.away,
    super.key,
  });

  final ({List<Json> home, List<Json> away}) best;
  final Entity home;
  final Entity away;

  static const _maxShown = 2;

  Widget _side(String side, List<Json> players, Entity team) {
    final shown = players.take(_maxShown).toList();
    final end = side == 'away';
    return Column(
      crossAxisAlignment: end
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text(
          team.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: side == 'home' ? lime : awaySideColor,
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
        if (players.length > 1)
          Text(
            'Empatados',
            key: ValueKey('team-top-rated-$side-tie'),
            style: const TextStyle(color: muted, fontSize: 10.5),
          ),
        for (var i = 0; i < shown.length; i++) ...[
          const SizedBox(height: 8),
          _TeamTopRatedPlayer(
            key: ValueKey('team-top-rated-$side-$i'),
            player: shown[i],
            alignEnd: end,
            compact: shown.length > 1,
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .04),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: _cardBorder),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: best.home.isEmpty
              ? const SizedBox.shrink()
              : _side('home', best.home, home),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: best.away.isEmpty
              ? const SizedBox.shrink()
              : _side('away', best.away, away),
        ),
      ],
    ),
  );
}

class _TeamTopRatedPlayer extends StatelessWidget {
  const _TeamTopRatedPlayer({
    required this.player,
    required this.alignEnd,
    required this.compact,
    super.key,
  });

  final Json player;
  final bool alignEnd;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final name = player['name']?.toString() ?? 'Jugador';
    final position = _positionLabel(player['position']);
    final canonicalId = player['canonicalId']?.toString();
    final canOpenProfile = canonicalId != null && canonicalId.isNotEmpty;
    final text = Expanded(
      child: Column(
        crossAxisAlignment: alignEnd
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: alignEnd ? TextAlign.end : TextAlign.start,
            style: TextStyle(
              fontSize: compact ? 12 : 13,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 3),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (position != null && !alignEnd) ...[
                Flexible(
                  child: Text(
                    position,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: muted, fontSize: 11),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              _RatingBadge(player['rating'] as num),
              if (position != null && alignEnd) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    position,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: muted, fontSize: 11),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
    final avatar = _PlayerAvatar(player, size: compact ? 30 : 40);
    final content = Row(
      children: alignEnd
          ? [text, const SizedBox(width: 8), avatar]
          : [avatar, const SizedBox(width: 8), text],
    );
    if (!canOpenProfile) return content;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => context.push('/player/$canonicalId'),
      child: content,
    );
  }
}

class _TopRatedEntry extends StatelessWidget {
  const _TopRatedEntry({
    required this.entry,
    required this.teamName,
    this.prominent = false,
    super.key,
  });

  final ({Json player, String side}) entry;
  final String teamName;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final player = entry.player;
    final name = player['name']?.toString() ?? 'Jugador';
    final canonicalId = player['canonicalId']?.toString();
    final canOpenProfile = canonicalId != null && canonicalId.isNotEmpty;

    final content = Row(
      children: [
        _PlayerAvatar(player, size: prominent ? 52 : 38),
        SizedBox(width: prominent ? 12 : 8),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: prominent ? 15 : 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                teamName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: muted, fontSize: 11),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _RatingBadge(player['rating'] as num),
      ],
    );

    if (!canOpenProfile) return content;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => context.push('/player/$canonicalId'),
      child: content,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 14, 2, 8),
    child: Text(
      title,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
    ),
  );
}

const _weekdays = ['lun', 'mar', 'mié', 'jue', 'vie', 'sáb', 'dom'];
const _months = [
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

String matchDateLabel(DateTime date) {
  final weekday = _weekdays[date.weekday - 1];
  return '${weekday[0].toUpperCase()}${weekday.substring(1)} '
      '${date.day} ${_months[date.month - 1]}';
}

class MatchHero extends StatelessWidget {
  const MatchHero({
    required this.data,
    required this.match,
    required this.competition,
    required this.detail,
    required this.venue,
    super.key,
  });

  final Snapshot data;
  final FootballMatch match;
  final Entity competition;
  final MatchDetail detail;
  final String venue;

  @override
  Widget build(BuildContext context) {
    final home = data.team(match.homeId)!;
    final away = data.team(match.awayId)!;
    final round = detail.round?.trim() ?? '';
    final date = matchDateLabel(match.startTime);
    final time = localTime(context, match.startTime);
    // Scorers only once the match has started and a goal has a known side.
    final summary = match.showKickoff
        ? null
        : matchScorerSummary(match, detail, data);
    final scorers =
        summary != null && (summary.home.isNotEmpty || summary.away.isNotEmpty)
        ? summary
        : null;

    return Container(
      key: const ValueKey('match-hero'),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_headerTop, _headerBottom],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Competition first, clearly separated from the teams.
          Material(
            color: Colors.white.withValues(alpha: .06),
            shape: const StadiumBorder(),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: () => context.push('/competition/${competition.id}'),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 30),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.emoji_events_outlined,
                        size: 14,
                        color: lime,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          [
                            competition.name,
                            if (round.isNotEmpty) 'Jornada $round',
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right_rounded,
                        size: 16,
                        color: muted,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _HeaderTeam(home, accent: lime)),
              SizedBox(width: 112, child: _HeaderCenter(match)),
              Expanded(child: _HeaderTeam(away, accent: awaySideColor)),
            ],
          ),
          if (scorers != null) ...[
            const SizedBox(height: 10),
            _HeaderScorers(home: scorers.home, away: scorers.away),
          ],
          if (!match.showKickoff || venue.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                if (!match.showKickoff)
                  _InfoChip(Icons.calendar_today_rounded, '$date · $time'),
                if (venue.trim().isNotEmpty)
                  _InfoChip(Icons.location_on_outlined, venue.trim()),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _HeaderTeam extends StatelessWidget {
  const _HeaderTeam(this.team, {required this.accent});

  final Entity team;

  /// Side color (home lime / away blue), shared with the standings highlight.
  final Color accent;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: team.name,
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => context.push('/team/${team.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: .05),
                border: Border.all(color: Colors.white.withValues(alpha: .08)),
              ),
              child: EntityAvatar(team, size: 46),
            ),
            const SizedBox(height: 8),
            Text(
              team.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13.5,
                height: 1.15,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              width: 18,
              height: 3,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _HeaderCenter extends StatelessWidget {
  const _HeaderCenter(this.match);

  final FootballMatch match;

  @override
  Widget build(BuildContext context) {
    final (color, _) = matchStatusTone(match);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        children: [
          if (match.showKickoff) ...[
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                localTime(context, match.startTime),
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w900,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              matchDateLabel(match.startTime),
              style: const TextStyle(color: muted, fontSize: 12),
            ),
          ] else
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                match.score,
                style: TextStyle(
                  fontSize: 38,
                  height: 1.05,
                  letterSpacing: 1,
                  fontWeight: FontWeight.w900,
                  color: match.isLive && match.status != 'HALFTIME'
                      ? color
                      : Colors.white,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          const SizedBox(height: 8),
          FittedBox(fit: BoxFit.scaleDown, child: _MatchStatePill(match)),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .05),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: muted),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
      ],
    ),
  );
}

/// Visual tone of the match state: color and whether it is in play.
(Color, bool) matchStatusTone(FootballMatch match) {
  if (match.isAwaitingUpdate && match.hasPlayedEvidence) {
    return (Colors.amber, false);
  }
  return switch (match.status) {
    'LIVE' || 'EXTRA_TIME' || 'PENALTIES' => (lime, true),
    'HALFTIME' => (Colors.amber, true),
    'VERIFIED' || 'FINISHED_PENDING_VERIFICATION' => (Colors.white, false),
    'POSTPONED' ||
    'SUSPENDED' ||
    'ABANDONED' ||
    'CANCELLED' => (Colors.redAccent, false),
    _ => (muted, false),
  };
}

class _MatchStatePill extends StatelessWidget {
  const _MatchStatePill(this.match);

  final FootballMatch match;

  @override
  Widget build(BuildContext context) {
    final label = match.statusLabel;
    if (label.isEmpty) return const SizedBox.shrink();
    final (color, inPlay) = matchStatusTone(match);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: .45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (inPlay) ...[
            Icon(Icons.circle, size: 8, color: color),
            const SizedBox(width: 6),
          ],
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w900,
              letterSpacing: .8,
            ),
          ),
        ],
      ),
    );
  }
}

class MatchInfoCard extends StatelessWidget {
  const MatchInfoCard({
    required this.match,
    required this.competition,
    required this.detail,
    required this.venue,
    super.key,
  });

  final FootballMatch match;
  final Entity competition;
  final MatchDetail detail;
  final String venue;

  @override
  Widget build(BuildContext context) {
    final round = detail.round?.trim() ?? '';
    final referee = detail.referee?.trim() ?? '';
    final rows = <(IconData, String, String)>[
      (Icons.emoji_events_outlined, 'Competición', competition.name),
      if (round.isNotEmpty)
        (Icons.format_list_numbered_rounded, 'Jornada', round),
      (
        Icons.calendar_today_rounded,
        'Fecha',
        '${matchDateLabel(match.startTime)} · '
            '${localTime(context, match.startTime)}',
      ),
      if (venue.trim().isNotEmpty)
        (Icons.location_on_outlined, 'Estadio', venue.trim()),
      if (referee.isNotEmpty) (Icons.sports_rounded, 'Árbitro', referee),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Column(
          children: [
            for (final (icon, label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(icon, size: 18, color: muted),
                    const SizedBox(width: 12),
                    Text(
                      label,
                      style: const TextStyle(color: muted, fontSize: 13),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        value,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class PostMatchVideos extends StatelessWidget {
  const PostMatchVideos(this.detail, {super.key});

  final MatchDetail detail;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final video in detail.videos)
        Card(
          child: ListTile(
            leading: const CircleAvatar(child: Icon(Icons.play_arrow_rounded)),
            title: Text(
              video['title']?.toString() ?? 'Resumen del partido',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              [
                video['channelName']?.toString() ?? '',
                video['source']?.toString() ?? '',
              ].where((value) => value.trim().isNotEmpty).join(' · '),
            ),
            trailing: IconButton(
              tooltip: 'Copiar enlace de YouTube',
              icon: const Icon(Icons.link),
              onPressed: () async {
                final url = video['url']?.toString() ?? '';
                if (!url.startsWith('https://www.youtube.com/watch?v=')) return;
                await Clipboard.setData(ClipboardData(text: url));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Enlace de YouTube copiado')),
                );
              },
            ),
          ),
        ),
    ],
  );
}

/// Discrete inline indicator for a section whose detail is still arriving.
class _PendingSection extends StatelessWidget {
  const _PendingSection(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 18),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(label, style: const TextStyle(color: muted)),
        ),
      ],
    ),
  );
}

/// Match Center Tabla content: the exact competition+season table, or one
/// stable state (loading while the bounded refresh runs, then settled).
class MatchStandingsTab extends StatelessWidget {
  const MatchStandingsTab(
    this.data,
    this.competitionId, {
    super.key,
    required this.refreshing,
    this.homeTeamId,
    this.awayTeamId,
    this.onRetry,
  });

  final Snapshot data;
  final String competitionId;

  /// The selected match's sides, highlighted in the table.
  final String? homeTeamId;
  final String? awayTeamId;

  /// A visible refresh for this table is running (bounded or manual).
  final bool refreshing;

  /// Manual refresh offered once a pending table settled.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final hasRows = data.standings.any(
      (table) =>
          table['competitionId'] == competitionId &&
          (table['rows'] as List? ?? const []).isNotEmpty,
    );
    if (hasRows) {
      // A stale table stays on screen while it is revalidated.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (refreshing)
            const Padding(
              key: ValueKey('standings-updating'),
              padding: EdgeInsets.only(bottom: 4),
              child: Text(
                'Actualizando tabla…',
                style: TextStyle(color: muted, fontSize: 12),
              ),
            ),
          Standings(
            data,
            competitionId,
            selectableView: true,
            highlightedTeams: {?homeTeamId: lime, ?awayTeamId: awaySideColor},
            // In-play evidence from the snapshot itself (never the clock).
            liveTeamIds: liveTeamIds(data, competitionId),
          ),
        ],
      );
    }
    if (data.standingsPending || data.standingsState == 'pending') {
      if (refreshing) return const _PendingSection('Cargando tabla…');
      // Settled: no spinner. Slow silent revalidations may still bring it.
      return Column(
        children: [
          const _EmptySection(
            Icons.table_rows_outlined,
            'Tabla aún no disponible',
          ),
          if (onRetry != null)
            OutlinedButton.icon(
              key: const ValueKey('standings-retry'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Reintentar'),
            ),
        ],
      );
    }
    // NO_DATA negative cache, missing or not fetchable: no retry action.
    // unavailable (provider has no table), missing or not fetchable.
    return const _EmptySection(
      Icons.table_rows_outlined,
      'Sin tabla disponible',
    );
  }
}

class _EmptySection extends StatelessWidget {
  const _EmptySection(this.icon, this.label);

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 22),
    child: Column(
      children: [
        Icon(icon, size: 30, color: muted.withValues(alpha: .6)),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: muted)),
      ],
    ),
  );
}

class _StatsLegend extends StatelessWidget {
  const _StatsLegend({required this.home, required this.away});

  final Entity home;
  final Entity away;

  @override
  Widget build(BuildContext context) {
    Widget side(Entity team, Color color, {required bool end}) => Expanded(
      child: Row(
        mainAxisAlignment: end
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          if (!end) ...[EntityAvatar(team, size: 26), const SizedBox(width: 8)],
          Flexible(
            child: Text(
              team.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: end ? TextAlign.end : TextAlign.start,
              style: TextStyle(color: color, fontWeight: FontWeight.w800),
            ),
          ),
          if (end) ...[const SizedBox(width: 8), EntityAvatar(team, size: 26)],
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          side(home, lime, end: false),
          const SizedBox(width: 12),
          side(away, awaySideColor, end: true),
        ],
      ),
    );
  }
}

class Statistics extends StatelessWidget {
  const Statistics(this.match, {this.detail, this.limit, super.key});
  final FootballMatch match;
  final MatchDetail? detail;
  final int? limit;

  @override
  Widget build(BuildContext context) {
    final stats = detail?.statistics.isNotEmpty == true
        ? detail!.statistics
        : match.statistics;
    if (stats.isEmpty) {
      if (detail?.statisticsPending == true) {
        return const _PendingSection('Cargando estadísticas…');
      }
      return const _EmptySection(Icons.bar_chart_rounded, 'Sin estadísticas');
    }
    final ordered = orderedStatistics(stats);
    final visible = limit == null ? ordered : ordered.take(limit!).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
        child: Column(
          children: [for (final stat in visible) _StatisticComparison(stat)],
        ),
      ),
    );
  }
}

/// Provider statistic name: normalized rows use `label`, raw rows `type`.
String statisticName(Json stat) =>
    (stat['label'] ?? stat['type'])?.toString() ?? '';

/// Keeps provider order but lifts possession first, as football apps do.
List<Json> orderedStatistics(List<Json> stats) {
  bool isPossession(Json stat) =>
      _statKey(statisticName(stat)).contains('possession');
  return [
    ...stats.where(isPossession),
    ...stats.where((s) => !isPossession(s)),
  ];
}

class _StatisticComparison extends StatelessWidget {
  const _StatisticComparison(this.stat);

  final Json stat;

  @override
  Widget build(BuildContext context) {
    final home = statNumericValue(stat['home']);
    final away = statNumericValue(stat['away']);
    final comparable = home != null && away != null && home >= 0 && away >= 0;
    final total = comparable ? home + away : 0.0;
    final homeLeads = comparable && home > away;
    final awayLeads = comparable && away > home;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Column(
        children: [
          Row(
            children: [
              _StatValuePill(
                _statValue(stat['home'], stat['unit']),
                color: lime,
                highlighted: homeLeads,
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    _statLabel(statisticName(stat)),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              _StatValuePill(
                _statValue(stat['away'], stat['unit']),
                color: awaySideColor,
                highlighted: awayLeads,
              ),
            ],
          ),
          if (comparable) ...[
            const SizedBox(height: 7),
            Row(
              key: const ValueKey('stat-bars'),
              children: [
                Expanded(
                  child: _StatBar(
                    share: total > 0 ? home / total : 0,
                    color: homeLeads ? lime : lime.withValues(alpha: .45),
                    fromEnd: true,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _StatBar(
                    share: total > 0 ? away / total : 0,
                    color: awayLeads
                        ? awaySideColor
                        : awaySideColor.withValues(alpha: .45),
                    fromEnd: false,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StatValuePill extends StatelessWidget {
  const _StatValuePill(
    this.text, {
    required this.color,
    required this.highlighted,
  });

  final String text;
  final Color color;
  final bool highlighted;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 44, maxWidth: 88),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: highlighted ? color : Colors.transparent,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: highlighted ? Colors.black : Colors.white,
        fontSize: 13,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

/// Half of a two-sided comparison bar; grows outward from the center.
class _StatBar extends StatelessWidget {
  const _StatBar({
    required this.share,
    required this.color,
    required this.fromEnd,
  });

  final double share;
  final Color color;
  final bool fromEnd;

  @override
  Widget build(BuildContext context) => Container(
    height: 6,
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .07),
      borderRadius: BorderRadius.circular(999),
    ),
    alignment: fromEnd ? Alignment.centerRight : Alignment.centerLeft,
    child: FractionallySizedBox(
      widthFactor: share.clamp(0, 1).toDouble(),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(999),
        ),
        child: const SizedBox.expand(),
      ),
    ),
  );
}

double? statNumericValue(dynamic value) {
  if (value is num) return value.toDouble();
  final raw = value?.toString().trim().replaceAll('%', '') ?? '';
  return double.tryParse(raw);
}

String _statValue(dynamic value, dynamic unit) {
  final text = value?.toString() ?? '—';
  final suffix = unit?.toString() ?? '';
  return '$text$suffix';
}

String _statKey(String value) => value
    .replaceAll('_', ' ')
    .trim()
    .toLowerCase()
    .split(RegExp(r'\s+'))
    .join(' ');

const _statLabels = {
  'possession': 'Posesión',
  'ball possession': 'Posesión',
  'possession %': 'Posesión',
  'shots': 'Tiros',
  'total shots': 'Tiros totales',
  'shots total': 'Tiros totales',
  'shots on target': 'Tiros a puerta',
  'shots on goal': 'Tiros a puerta',
  'on target': 'Tiros a puerta',
  'shots off target': 'Tiros desviados',
  'shots off goal': 'Tiros desviados',
  'off target': 'Tiros desviados',
  'blocked shots': 'Tiros bloqueados',
  'shots blocked': 'Tiros bloqueados',
  'shots inside box': 'Tiros dentro del área',
  'shots insidebox': 'Tiros dentro del área',
  'shots outside box': 'Tiros fuera del área',
  'shots outsidebox': 'Tiros fuera del área',
  'corners': 'Córners',
  'corner kicks': 'Córners',
  'fouls': 'Faltas',
  'offsides': 'Fueras de juego',
  'yellow cards': 'Tarjetas amarillas',
  'red cards': 'Tarjetas rojas',
  'saves': 'Atajadas',
  'goalkeeper saves': 'Atajadas',
  'passes': 'Pases',
  'total passes': 'Pases',
  'accurate passes': 'Pases precisos',
  'passes accurate': 'Pases precisos',
  'passes %': 'Precisión de pases',
  'pass accuracy': 'Precisión de pases',
  'expected goals': 'Goles esperados (xG)',
  'expected goals (xg)': 'Goles esperados (xG)',
  'xg': 'Goles esperados (xG)',
  'attacks': 'Ataques',
  'dangerous attacks': 'Ataques peligrosos',
  'free kicks': 'Tiros libres',
  'throw ins': 'Saques de banda',
  'throw-ins': 'Saques de banda',
  'goal kicks': 'Saques de meta',
  'tackles': 'Entradas',
  'crosses': 'Centros',
  'substitutions': 'Cambios',
};

String _statLabel(String value) {
  final key = _statKey(value);
  if (key.isEmpty) return 'Estadística';
  final known = _statLabels[key];
  if (known != null) return known;
  final clean = value.replaceAll('_', ' ').trim().split(RegExp(r'\s+'));
  final text = clean.join(' ');
  return '${text[0].toUpperCase()}${text.substring(1)}';
}

/// Resolves which side an event belongs to using only data already present.
/// Returns null when the side is genuinely unknown (never guessed).
String? timelineSide(Json event, FootballMatch match, Snapshot data) {
  final teamId = event['teamId']?.toString();
  if (teamId != null && teamId.isNotEmpty) {
    if (teamId == match.homeId) return 'home';
    if (teamId == match.awayId) return 'away';
  }
  for (final key in ['side', 'team']) {
    final raw = event[key]?.toString().trim().toLowerCase() ?? '';
    if (raw.isEmpty) continue;
    if (raw == 'home' || raw == 'local') return 'home';
    if (raw == 'away' || raw == 'visitor' || raw == 'visitante') return 'away';
    if (raw == data.team(match.homeId)?.name.toLowerCase()) return 'home';
    if (raw == data.team(match.awayId)?.name.toLowerCase()) return 'away';
  }
  return null;
}

const _neutralEvents = {'KICKOFF', 'HALFTIME', 'FULL_TIME'};

/// One header line: a real scorer with all their minutes on one side, or an
/// anonymous goal ("Gol 55′") that is never merged with another one.
class ScorerLine {
  ScorerLine(this.name, this.minutes);
  final String? name;
  final List<String> minutes;

  String get label => name == null
      ? 'Gol ${minutes.join(', ')}'
      : '$name ${minutes.join(', ')}';
}

/// #99 header scorers from the already-deduplicated timeline (#121): only
/// GOAL events with a known side. Name = the provider's structured
/// playerName, else the canonical player entity of its playerId (the same
/// identity the timeline shows); never parsed from free text or invented.
/// The same named player is grouped per side, anonymous goals never are.
({List<ScorerLine> home, List<ScorerLine> away}) matchScorerSummary(
  FootballMatch match,
  MatchDetail detail,
  Snapshot data,
) {
  final home = <ScorerLine>[], away = <ScorerLine>[];
  for (final event in mergedMatchTimeline(match, detail)) {
    if (event['type'] != 'GOAL') continue;
    final side = timelineSide(event, match, data);
    if (side == null) continue;
    final lines = side == 'home' ? home : away;
    final provided = event['playerName']?.toString().trim() ?? '';
    final name = provided.isNotEmpty
        ? provided
        : data.player(event['playerId']?.toString() ?? '')?.name.trim();
    final minute = eventMinuteLabel(event);
    if (name != null && name.isNotEmpty) {
      final existing = lines.where((line) => line.name == name).firstOrNull;
      if (existing != null) {
        existing.minutes.add(minute);
        continue;
      }
      lines.add(ScorerLine(name, [minute]));
    } else {
      lines.add(ScorerLine(null, [minute]));
    }
  }
  return (home: home, away: away);
}

class _HeaderScorers extends StatelessWidget {
  const _HeaderScorers({required this.home, required this.away});

  final List<ScorerLine> home, away;
  static const _maxLines = 5;

  Widget _column(List<ScorerLine> lines, String side, TextAlign align) {
    final shown = lines.take(_maxLines).toList();
    final hidden = lines.length - shown.length;
    return Column(
      crossAxisAlignment: side == 'home'
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < shown.length; i++)
          Text(
            shown[i].label,
            key: ValueKey('scorer-$side-$i'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: align,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11.5,
              height: 1.35,
              fontWeight: FontWeight.w600,
            ),
          ),
        if (hidden > 0)
          Text(
            '+$hidden',
            textAlign: align,
            style: const TextStyle(color: muted, fontSize: 11),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Row(
    key: const ValueKey('header-scorers'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(child: _column(home, 'home', TextAlign.end)),
      const SizedBox(
        width: 28,
        child: Icon(Icons.sports_soccer, size: 13, color: muted),
      ),
      Expanded(child: _column(away, 'away', TextAlign.start)),
    ],
  );
}

class MatchTimeline extends StatelessWidget {
  const MatchTimeline(this.data, this.match, this.detail, {super.key});

  final Snapshot data;
  final FootballMatch match;
  final MatchDetail detail;

  @override
  Widget build(BuildContext context) {
    final timeline = mergedMatchTimeline(match, detail);
    if (timeline.isEmpty) {
      if (detail.pending) return const _PendingSection('Cargando eventos…');
      return const _EmptySection(Icons.timeline_rounded, 'Sin eventos');
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            for (final event in timeline)
              _neutralEvents.contains(event['type'])
                  ? _TimelineDivider(event)
                  : _TimelineRow(
                      event: event,
                      data: data,
                      side: timelineSide(event, match, data),
                    ),
          ],
        ),
      ),
    );
  }
}

class _TimelineDivider extends StatelessWidget {
  const _TimelineDivider(this.event);

  final Json event;

  @override
  Widget build(BuildContext context) {
    final type = event['type']?.toString() ?? '';
    final line = Expanded(child: Container(height: 1, color: _cardBorder));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          line,
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .06),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(eventIcon(type), size: 14, color: eventColor(type)),
                const SizedBox(width: 5),
                Text(
                  eventLabel(type),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          line,
        ],
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.event,
    required this.data,
    required this.side,
  });

  final Json event;
  final Snapshot data;
  final String? side;

  @override
  Widget build(BuildContext context) {
    final type = event['type']?.toString() ?? '';
    final player = data.player(event['playerId']?.toString() ?? '');
    final team = data.team(event['teamId']?.toString() ?? '');
    final rawLabel = event['label']?.toString().trim() ?? '';
    final detailParts = (event['detail']?.toString() ?? '')
        .split(' · ')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    final typeLabel = type == 'OTHER' && rawLabel.isNotEmpty
        ? rawLabel
        : eventLabel(type);
    final title =
        player?.name ??
        (detailParts.isNotEmpty
            ? detailParts.first
            : rawLabel.isNotEmpty
            ? rawLabel
            : typeLabel);
    final subtitle = <String>[
      if (title != typeLabel) typeLabel,
      for (final part in detailParts)
        if (part != title) part,
      if (side == null && team != null) team.name,
    ].join(' · ');

    final content = _TimelineContent(
      type: type,
      title: title,
      subtitle: subtitle,
      alignEnd: side == 'home',
    );
    final minute = _MinuteBubble(eventMinuteLabel(event), type: type);

    final row = switch (side) {
      'home' => Row(
        children: [
          Expanded(child: content),
          minute,
          const Expanded(child: SizedBox()),
        ],
      ),
      'away' => Row(
        children: [
          const Expanded(child: SizedBox()),
          minute,
          Expanded(child: content),
        ],
      ),
      _ => Row(
        children: [
          minute,
          const SizedBox(width: 4),
          Expanded(child: content),
        ],
      ),
    };

    return InkWell(
      onTap: player == null
          ? null
          : () => context.push('/player/${event['playerId']}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: row,
      ),
    );
  }
}

class _MinuteBubble extends StatelessWidget {
  const _MinuteBubble(this.label, {required this.type});

  final String label;
  final String type;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 52,
    child: Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: type == 'GOAL'
              ? lime.withValues(alpha: .16)
              : Colors.white.withValues(alpha: .07),
          borderRadius: BorderRadius.circular(999),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label,
            style: TextStyle(
              color: type == 'GOAL' ? lime : Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    ),
  );
}

class _TimelineContent extends StatelessWidget {
  const _TimelineContent({
    required this.type,
    required this.title,
    required this.subtitle,
    required this.alignEnd,
  });

  final String type;
  final String title;
  final String subtitle;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final text = Flexible(
      child: Column(
        crossAxisAlignment: alignEnd
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: alignEnd ? TextAlign.end : TextAlign.start,
            style: TextStyle(
              fontSize: 13,
              height: 1.2,
              fontWeight: type == 'GOAL' ? FontWeight.w900 : FontWeight.w700,
            ),
          ),
          if (subtitle.isNotEmpty)
            Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: alignEnd ? TextAlign.end : TextAlign.start,
              style: const TextStyle(color: muted, fontSize: 11, height: 1.2),
            ),
        ],
      ),
    );
    final glyph = EventGlyph(type);
    return Row(
      mainAxisAlignment: alignEnd
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      children: alignEnd
          ? [text, const SizedBox(width: 8), glyph]
          : [glyph, const SizedBox(width: 8), text],
    );
  }
}

/// Distinct visual per event type (cards drawn as real cards).
class EventGlyph extends StatelessWidget {
  const EventGlyph(this.type, {this.size = 28, super.key});

  final String type;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = eventColor(type);
    final isCard = type == 'YELLOW_CARD' || type == 'RED_CARD';
    final isGoal = type == 'GOAL';
    return Semantics(
      label: eventLabel(type),
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isGoal ? lime : color.withValues(alpha: .14),
          border: isGoal
              ? null
              : Border.all(color: color.withValues(alpha: .4)),
        ),
        child: isCard
            ? Transform.rotate(
                angle: .12,
                child: Container(
                  width: size * .38,
                  height: size * .52,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              )
            : Icon(
                type == 'SUBSTITUTION'
                    ? Icons.swap_horiz_rounded
                    : eventIcon(type),
                size: size * .6,
                color: isGoal ? Colors.black : color,
              ),
      ),
    );
  }
}

class Lineups extends StatelessWidget {
  const Lineups(this.data, this.match, this.detail, {super.key});

  final Snapshot data;
  final FootballMatch match;
  final MatchDetail detail;

  @override
  Widget build(BuildContext context) {
    final hasPlayers =
        detail.homeStarters.isNotEmpty || detail.awayStarters.isNotEmpty;
    if (!hasPlayers) {
      if (detail.lineupPending) {
        return const _PendingSection('Cargando alineaciones…');
      }
      return const _EmptySection(Icons.groups_outlined, 'Sin alineaciones');
    }

    return Column(
      children: [
        _TeamLineup(
          team: data.team(match.homeId)!,
          formation: detail.homeFormation,
          starters: detail.homeStarters,
          substitutes: detail.homeSubstitutes,
          coach: detail.homeCoach,
          incidents: detail.incidents,
          side: 'home',
        ),
        const SizedBox(height: 14),
        _TeamLineup(
          team: data.team(match.awayId)!,
          formation: detail.awayFormation,
          starters: detail.awayStarters,
          substitutes: detail.awaySubstitutes,
          coach: detail.awayCoach,
          incidents: detail.incidents,
          side: 'away',
        ),
      ],
    );
  }
}

class _TeamLineup extends StatelessWidget {
  const _TeamLineup({
    required this.team,
    required this.formation,
    required this.starters,
    required this.substitutes,
    required this.coach,
    required this.incidents,
    required this.side,
  });

  final Entity team;
  final String? formation;
  final List<Json> starters;
  final List<Json> substitutes;
  final Json? coach;
  final List<Json> incidents;
  final String side;

  @override
  Widget build(BuildContext context) {
    final pitchRows = adaptiveFormationRows(formation, starters);
    final accent = side == 'home' ? lime : awaySideColor;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                EntityAvatar(team, size: 34),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    team.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (formation != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: accent.withValues(alpha: .5)),
                    ),
                    child: Text(
                      formation!,
                      style: TextStyle(
                        color: accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (starters.isNotEmpty) ...[
              const _LineupLabel('Titulares'),
              const SizedBox(height: 8),
              _FormationPitch(pitchRows, incidents: incidents, side: side),
            ],
            if (substitutes.isNotEmpty) ...[
              const SizedBox(height: 16),
              const _LineupLabel('Suplentes'),
              const SizedBox(height: 8),
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 460 ? 3 : 2;
                  return GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: substitutes.length,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisExtent: 70,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemBuilder: (_, index) => _BenchPlayer(
                      substitutes[index],
                      events: lineupEventsForPlayer(
                        substitutes[index],
                        incidents,
                        side,
                      ),
                    ),
                  );
                },
              ),
            ],
            if (coach != null) ...[
              const SizedBox(height: 16),
              const _LineupLabel('Entrenador'),
              const SizedBox(height: 8),
              _CoachTile(coach!),
            ],
          ],
        ),
      ),
    );
  }
}

class _LineupLabel extends StatelessWidget {
  const _LineupLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      color: muted,
      fontSize: 12,
      letterSpacing: .4,
      fontWeight: FontWeight.w800,
    ),
  );
}

List<List<Json>>? formationPlayerRows(String? formation, List<Json> starters) {
  if (formation == null || starters.length != 11) return null;
  final parts = formation
      .split('-')
      .map(int.tryParse)
      .whereType<int>()
      .where((value) => value > 0)
      .toList();
  if (parts.isEmpty || parts.fold<int>(1, (sum, value) => sum + value) != 11) {
    return null;
  }

  final ordered = [...starters]
    ..sort(
      (a, b) => (a['lineupPosition'] as num? ?? 999).compareTo(
        b['lineupPosition'] as num? ?? 999,
      ),
    );

  var offset = 1;
  final rows = <List<Json>>[
    [ordered.first],
  ];
  for (final size in parts) {
    rows.add(ordered.sublist(offset, offset + size));
    offset += size;
  }
  return rows.reversed.toList();
}

List<List<Json>> adaptiveFormationRows(String? formation, List<Json> starters) {
  final declared = formationPlayerRows(formation, starters);
  if (declared != null) return declared;
  if (starters.isEmpty) return const [];

  final ordered = [...starters]
    ..sort(
      (a, b) => (a['lineupPosition'] as num? ?? 999).compareTo(
        b['lineupPosition'] as num? ?? 999,
      ),
    );
  final groups = <int, List<Json>>{};
  for (final player in ordered) {
    groups.putIfAbsent(_positionBand(player['position']), () => []).add(player);
  }
  if (groups.length > 1) {
    return [
      for (final key in groups.keys.toList()..sort((a, b) => b - a))
        groups[key]!,
    ];
  }

  final rows = <List<Json>>[];
  for (var index = 0; index < ordered.length; index += 4) {
    rows.add(ordered.sublist(index, (index + 4).clamp(0, ordered.length)));
  }
  return rows.reversed.toList();
}

int _positionBand(dynamic raw) {
  final value = raw?.toString().toLowerCase() ?? '';
  if (value.contains('goal') || value == 'gk' || value.contains('portero')) {
    return 0;
  }
  if (value.contains('def') ||
      value == 'cb' ||
      value == 'lb' ||
      value == 'rb') {
    return 1;
  }
  if (value.contains('mid') || value.contains('medio') || value == 'cm') {
    return 2;
  }
  if (value.contains('for') ||
      value.contains('att') ||
      value.contains('wing')) {
    return 3;
  }
  return 2;
}

class LineupPlayerEvent {
  const LineupPlayerEvent(this.type, this.minute, {this.role});
  final String type;
  final int? minute;
  final String? role;
}

List<LineupPlayerEvent> lineupEventsForPlayer(
  Json player,
  List<Json> incidents,
  String side,
) {
  final id = player['id']?.toString().trim();
  if (id == null || id.isEmpty) return const [];
  final result = <LineupPlayerEvent>[];
  for (final incident in incidents) {
    final incidentSide =
        incident['side']?.toString() ?? incident['team']?.toString() ?? '';
    if (incidentSide.isNotEmpty && incidentSide != side) continue;
    final type = incident['type']?.toString() ?? 'OTHER';
    final minute = incident['minute'] as int?;
    if (incident['playerId']?.toString() == id) {
      result.add(LineupPlayerEvent(type, minute));
    }
    if (incident['assistPlayerId']?.toString() == id) {
      result.add(LineupPlayerEvent('ASSIST', minute));
    }
    if (incident['outPlayerId']?.toString() == id) {
      result.add(LineupPlayerEvent('SUB_OUT', minute, role: 'out'));
    }
    if (incident['inPlayerId']?.toString() == id) {
      result.add(LineupPlayerEvent('SUB_IN', minute, role: 'in'));
    }
  }
  return result;
}

class _FormationPitch extends StatelessWidget {
  const _FormationPitch(
    this.rows, {
    required this.incidents,
    required this.side,
  });

  final List<List<Json>> rows;
  final List<Json> incidents;
  final String side;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(16),
    child: CustomPaint(
      painter: const _PitchPainter(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 20),
        constraints: BoxConstraints(
          minHeight: (rows.length >= 4 ? 420 : 100 + rows.length * 86)
              .toDouble(),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (final row in rows)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final player in row)
                    Expanded(
                      child: _PitchPlayer(
                        player,
                        events: lineupEventsForPlayer(player, incidents, side),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    ),
  );
}

class _PitchPainter extends CustomPainter {
  const _PitchPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1B5E43), Color(0xFF134832)],
        ).createShader(rect),
    );
    final stripe = Paint()..color = const Color(0x10FFFFFF);
    for (var i = 0; i < 10; i += 2) {
      canvas.drawRect(
        Rect.fromLTWH(0, size.height * i / 10, size.width, size.height / 10),
        stripe,
      );
    }
    final line = Paint()
      ..color = Colors.white.withValues(alpha: .32)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final field = Rect.fromLTWH(8, 8, size.width - 16, size.height - 16);
    canvas.drawRect(field, line);
    final center = Offset(size.width / 2, size.height / 2);
    canvas.drawLine(
      Offset(8, center.dy),
      Offset(size.width - 8, center.dy),
      line,
    );
    canvas.drawCircle(
      center,
      (size.width * .13).clamp(24, 44).toDouble(),
      line,
    );
    canvas.drawCircle(
      center,
      2.5,
      Paint()..color = Colors.white.withValues(alpha: .4),
    );
    for (final y in [8.0, size.height - 8]) {
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset(size.width / 2, y),
          width: size.width * .52,
          height: 84,
        ),
        line,
      );
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset(size.width / 2, y),
          width: size.width * .24,
          height: 34,
        ),
        line,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

String _pitchName(String name) {
  final words = name.trim().split(RegExp(r'\s+'));
  // Surname like football apps; keep the full name when the last token is
  // not a real surname (a number or an initial).
  final last = words.last;
  return words.length > 1 && RegExp(r'\p{L}{2,}', unicode: true).hasMatch(last)
      ? last
      : name;
}

class _PitchPlayer extends StatelessWidget {
  const _PitchPlayer(this.player, {required this.events});

  final Json player;
  final List<LineupPlayerEvent> events;

  @override
  Widget build(BuildContext context) {
    final name = player['name']?.toString() ?? 'Jugador';
    final number = player['number']?.toString().trim() ?? '';
    final canonicalId = player['canonicalId']?.toString();
    final canOpenProfile = canonicalId != null && canonicalId.isNotEmpty;

    final content = Column(
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [
                  BoxShadow(color: Color(0x66000000), blurRadius: 6),
                ],
              ),
              child: _PlayerAvatar(player, size: 42),
            ),
            if (number.isNotEmpty)
              Positioned(left: -7, bottom: -3, child: _NumberBadge(number)),
            if (player['rating'] is num)
              Positioned(
                right: -9,
                top: -5,
                child: _RatingBadge(player['rating'] as num),
              ),
            if (player['captain'] == true)
              const Positioned(left: -7, top: -5, child: _CaptainBadge()),
          ],
        ),
        const SizedBox(height: 5),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .38),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            _pitchName(name),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (events.isNotEmpty) ...[
          const SizedBox(height: 3),
          _PlayerEvents(events),
        ],
      ],
    );

    if (!canOpenProfile) return content;
    return InkWell(
      borderRadius: BorderRadius.circular(28),
      onTap: () => context.push('/player/$canonicalId'),
      child: content,
    );
  }
}

class _NumberBadge extends StatelessWidget {
  const _NumberBadge(this.number);
  final String number;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 18),
    height: 18,
    padding: const EdgeInsets.symmetric(horizontal: 3),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: const Color(0xFF0B1114),
      borderRadius: BorderRadius.circular(9),
      border: Border.all(color: Colors.white.withValues(alpha: .7)),
    ),
    child: Text(
      number,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 9,
        fontWeight: FontWeight.w900,
      ),
    ),
  );
}

String? _positionLabel(dynamic raw) {
  final value = raw?.toString().trim() ?? '';
  if (value.isEmpty) return null;
  final lower = value.toLowerCase();
  if (lower.contains('goal') || lower == 'gk') return 'Portero';
  if (lower.contains('def')) return 'Defensa';
  if (lower.contains('mid')) return 'Centrocampista';
  if (lower.contains('for') || lower.contains('att')) return 'Delantero';
  return value;
}

class _BenchPlayer extends StatelessWidget {
  const _BenchPlayer(this.player, {required this.events});
  final Json player;
  final List<LineupPlayerEvent> events;

  @override
  Widget build(BuildContext context) {
    final number = player['number']?.toString().trim() ?? '';
    final position = _positionLabel(player['position']);
    final canonicalId = player['canonicalId']?.toString();
    final canOpenProfile = canonicalId != null && canonicalId.isNotEmpty;

    final content = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _cardBorder),
      ),
      child: Row(
        children: [
          _PlayerAvatar(player, size: 38),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  player['name']?.toString() ?? 'Jugador',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  [if (number.isNotEmpty) '#$number', ?position].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: muted, fontSize: 10),
                ),
                if (events.isNotEmpty) _PlayerEvents(events),
              ],
            ),
          ),
          if (player['rating'] is num) _RatingBadge(player['rating'] as num),
        ],
      ),
    );

    if (!canOpenProfile) return content;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => context.push('/player/$canonicalId'),
      child: content,
    );
  }
}

class _CoachTile extends StatelessWidget {
  const _CoachTile(this.coach);
  final Json coach;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .04),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: _cardBorder),
    ),
    child: Row(
      children: [
        _PlayerAvatar(coach, size: 38),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            coach['name']?.toString() ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
  );
}

/// Existing canonical photo only; the fallback stays underneath while the
/// image loads or if it fails, so there is no per-player spinner or broken
/// image. No additional photo requests are made here.
class _PlayerAvatar extends StatelessWidget {
  const _PlayerAvatar(this.player, {required this.size});
  final Json player;
  final double size;

  @override
  Widget build(BuildContext context) {
    final image = playerImage(player);
    final initials = _playerInitials(player['name']);
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2A3B36), Color(0xFF1A2622)],
        ),
        border: Border.all(color: lime.withValues(alpha: .45)),
      ),
      child: Text(
        initials.isNotEmpty ? initials : player['number']?.toString() ?? '',
        style: TextStyle(
          color: Colors.white,
          fontSize: size * .32,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
    if (image == null || image.isEmpty) return fallback;
    final pixels = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          fallback,
          ClipOval(
            child: Image.network(
              image,
              width: size,
              height: size,
              cacheWidth: pixels,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              errorBuilder: (_, error, stack) => const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }
}

String _playerInitials(dynamic name) {
  final words =
      name?.toString().trim().split(RegExp(r'\s+')) ?? const <String>[];
  return words
      .where((word) => word.isNotEmpty)
      .take(2)
      .map((word) => word[0])
      .join()
      .toUpperCase();
}

class _RatingBadge extends StatelessWidget {
  const _RatingBadge(this.rating);
  final num rating;

  @override
  Widget build(BuildContext context) {
    final value = rating.toDouble();
    final color = value >= 8
        ? lime
        : value >= 7
        ? Colors.amber
        : Colors.orangeAccent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        value.toStringAsFixed(1),
        style: const TextStyle(
          color: Colors.black,
          fontSize: 9,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _CaptainBadge extends StatelessWidget {
  const _CaptainBadge();
  @override
  Widget build(BuildContext context) => Container(
    width: 18,
    height: 18,
    alignment: Alignment.center,
    decoration: const BoxDecoration(
      color: Colors.white,
      shape: BoxShape.circle,
    ),
    child: const Text(
      'C',
      style: TextStyle(
        color: Colors.black,
        fontSize: 10,
        fontWeight: FontWeight.w900,
      ),
    ),
  );
}

class _PlayerEvents extends StatelessWidget {
  const _PlayerEvents(this.events);
  final List<LineupPlayerEvent> events;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 3,
    runSpacing: 2,
    alignment: WrapAlignment.center,
    children: [for (final event in events) _LineupEventIcon(event)],
  );
}

class _LineupEventIcon extends StatelessWidget {
  const _LineupEventIcon(this.event);
  final LineupPlayerEvent event;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (event.type) {
      'GOAL' => (Icons.sports_soccer, Colors.white),
      'ASSIST' => (Icons.assistant_rounded, lime),
      'YELLOW_CARD' => (Icons.square_rounded, Colors.amber),
      'RED_CARD' => (Icons.square_rounded, Colors.redAccent),
      'SUB_IN' => (Icons.arrow_upward_rounded, lime),
      'SUB_OUT' => (Icons.arrow_downward_rounded, Colors.redAccent),
      _ => (Icons.circle, muted),
    };
    final minute = event.minute == null ? '' : " ${event.minute}′";
    return Tooltip(
      message: '${eventLabel(event.type)}$minute',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          if (event.minute != null)
            Text(
              '${event.minute}′',
              style: const TextStyle(fontSize: 8, color: Colors.white70),
            ),
        ],
      ),
    );
  }
}

class EventBadge extends StatelessWidget {
  const EventBadge(this.type, {super.key});
  final String type;

  @override
  Widget build(BuildContext context) {
    final color = eventColor(type);
    return Semantics(
      label: eventLabel(type),
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: .42)),
        ),
        child: Icon(eventIcon(type), size: 20, color: color),
      ),
    );
  }
}

IconData eventIcon(String type) => switch (type) {
  'GOAL' => Icons.sports_soccer,
  'YELLOW_CARD' || 'RED_CARD' => Icons.square_rounded,
  'SUBSTITUTION' => Icons.swap_vert_rounded,
  'VAR' => Icons.tv_rounded,
  'MISSED_PENALTY' => Icons.cancel_outlined,
  'KICKOFF' => Icons.play_arrow_rounded,
  'HALFTIME' => Icons.pause_rounded,
  'FULL_TIME' => Icons.flag_rounded,
  _ => Icons.more_horiz_rounded,
};

Color eventColor(String type) => switch (type) {
  'GOAL' => lime,
  'YELLOW_CARD' => Colors.amber,
  'RED_CARD' => Colors.redAccent,
  'SUBSTITUTION' => Colors.lightBlueAccent,
  'VAR' => Colors.purpleAccent,
  'MISSED_PENALTY' => Colors.orangeAccent,
  'KICKOFF' || 'FULL_TIME' => Colors.white,
  'HALFTIME' => muted,
  _ => muted,
};

String eventLabel(String type) => switch (type) {
  'GOAL' => 'Gol',
  'YELLOW_CARD' => 'Tarjeta amarilla',
  'RED_CARD' => 'Tarjeta roja',
  'SUBSTITUTION' => 'Sustitución',
  'SUB_IN' => 'Entró',
  'SUB_OUT' => 'Salió',
  'ASSIST' => 'Asistencia',
  'VAR' => 'VAR',
  'MISSED_PENALTY' => 'Penal fallado',
  'KICKOFF' => 'Inicio',
  'HALFTIME' => 'Medio tiempo',
  'FULL_TIME' => 'Final',
  _ => 'Evento',
};

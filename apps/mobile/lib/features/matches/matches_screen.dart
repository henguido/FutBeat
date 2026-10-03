import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/interests.dart';
import '../../core/database.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/relevance.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';

/// "Favoritos" is only for matches of a favourite TEAM (never a followed
/// league, never a single followed match: those only mark the follow).
bool _isFollowedTeamMatch(FootballMatch match, Set<String> follows) =>
    follows.contains('team:${match.homeId}') ||
    follows.contains('team:${match.awayId}');

// Lower is better: finished, live, played evidence, scheduled, called off.
int _fixtureRank(FootballMatch match) {
  if (match.isFinished) return 0;
  if (match.isLive) return 1;
  if (const {
    'POSTPONED',
    'CANCELLED',
    'ABANDONED',
    'SUSPENDED',
  }.contains(match.status)) {
    return 4;
  }
  return match.hasPlayedEvidence ? 2 : 3;
}

bool _isGhostFixture(FootballMatch match) =>
    match.isScheduled && !match.hasPlayedEvidence;

bool _isPlayedOrPlaying(FootballMatch match) =>
    match.isFinished || match.isLive;

/// Whether two matches of the day are the same real fixture. Mirrors the
/// backend calendar rule with the evidence a client has; canonical ids
/// only, never display names.
///
/// Always required: same canonical competition, home team and away team.
/// Then: kickoff within 5 minutes; or within 3 hours when at most one of
/// the two shows played evidence (two games that were both really played
/// are two games); or within 24 hours when one is a scheduled ghost that
/// kicks off BEFORE the other, finished or live, one (its time passed with
/// no evidence; a later scheduled game can be a real second game). Two
/// finished matches with different final scores, and matches of different
/// competitions, are never merged.
bool _sameFixture(FootballMatch a, FootballMatch b) {
  if (a.competitionId.isEmpty ||
      a.competitionId != b.competitionId ||
      a.homeId.isEmpty ||
      a.homeId == a.awayId ||
      a.homeId != b.homeId ||
      a.awayId != b.awayId) {
    return false;
  }
  if (a.isFinished &&
      b.isFinished &&
      a.json['score'] != null &&
      b.json['score'] != null &&
      a.score != b.score) {
    return false;
  }
  final apart = a.startTime.difference(b.startTime).abs();
  if (apart <= const Duration(minutes: 5)) return true;
  bool evidence(FootballMatch m) =>
      _isPlayedOrPlaying(m) || m.hasPlayedEvidence;
  if (apart <= const Duration(hours: 3) && !(evidence(a) && evidence(b))) {
    return true;
  }
  bool ghostBefore(FootballMatch ghost, FootballMatch played) =>
      _isGhostFixture(ghost) &&
      _isPlayedOrPlaying(played) &&
      ghost.startTime.isBefore(played.startTime);
  return apart <= const Duration(hours: 24) &&
      (ghostBefore(a, b) || ghostBefore(b, a));
}

/// Defensive UI-level dedupe (the backend calendar is the authority): the
/// daily feed renders one canonical fixture exactly once: the same canonical
/// match id, or two match entities of one fixture (see [_sameFixture]). The
/// best twin stays: finished > live > played evidence > scheduled > called
/// off, then the lower id. The order of the surviving matches is preserved.
List<FootballMatch> dedupeFixtures(Iterable<FootballMatch> matches) {
  final kept = <FootballMatch>[];
  final seenIds = <String>{};
  for (final match in matches) {
    if (!seenIds.add(match.id)) continue;
    final twin = kept.indexWhere((other) => _sameFixture(match, other));
    if (twin < 0) {
      kept.add(match);
      continue;
    }
    final other = kept[twin];
    final byRank = _fixtureRank(match).compareTo(_fixtureRank(other));
    if (byRank < 0 || (byRank == 0 && match.id.compareTo(other.id) < 0)) {
      kept[twin] = match;
    }
  }
  return kept;
}

String _feedEventLabel(String type) => switch (type) {
  'GOAL' => 'Gol',
  'YELLOW_CARD' => 'Tarjeta amarilla',
  'RED_CARD' => 'Tarjeta roja',
  'SUBSTITUTION' => 'Sustitución',
  'VAR' => 'VAR',
  'MISSED_PENALTY' => 'Penal fallado',
  'KICKOFF' => 'Inicio',
  'HALFTIME' => 'Medio tiempo',
  'FULL_TIME' => 'Final',
  _ => 'Evento',
};

String _compactDate(DateTime value) {
  const months = [
    'ENE',
    'FEB',
    'MAR',
    'ABR',
    'MAY',
    'JUN',
    'JUL',
    'AGO',
    'SEP',
    'OCT',
    'NOV',
    'DIC',
  ];
  return '${value.day} ${months[value.month - 1]}';
}

String _dateContextLabel(DateTime value, DateTime today) {
  final date = DateUtils.dateOnly(value);
  final anchor = DateUtils.dateOnly(today);
  final difference = date.difference(anchor).inDays;
  if (difference == -1) return 'AYER';
  if (difference == 0) return 'HOY';
  if (difference == 1) return 'MAÑANA';
  const weekdays = ['LUN', 'MAR', 'MIÉ', 'JUE', 'VIE', 'SÁB', 'DOM'];
  return weekdays[date.weekday - 1];
}

/// Only the LIVE status is date-dependent; all other user filters survive.
String matchFilterForDate(String filter, DateTime selected, DateTime today) =>
    filter == 'En vivo' &&
        DateUtils.dateOnly(selected) != DateUtils.dateOnly(today)
    ? 'Todos'
    : filter;

/// Orders visible competitions without ever filtering the daily catalog.
///
/// The selected country (or the detected one) only REORDERS; every
/// competition with a match stays. Order:
///   1. pinned competitions, in the user's own order (personalized mode);
///   2. followed competitions;
///   3. the primary domestic competition of the user's country;
///   4. globally relevant competitions;
///   5. the other (secondary) competitions of the user's country;
///   6. everything else.
/// Inside a group, editorial relevance decides. A minor national competition
/// therefore never outranks a big global one: only the PRIMARY domestic one
/// does. Categories come from [competitionFeedCategory]. The stored "global
/// first" preference has no UI and is not applied ([orderPreference] is kept
/// only for source compatibility).
List<Entity> orderMatchCompetitions({
  required Snapshot data,
  required List<FootballMatch> matches,
  required Set<String> follows,
  String? selectedCountry,
  String? detectedCountry,
  String orderMode = CompetitionOrderMode.automatic,
  String orderPreference = CompetitionOrderPreference.countryFirst,
  List<String> pinnedCompetitionIds = const <String>[],
}) {
  final visibleCompetitionIds = matches
      .map((match) => match.competitionId)
      .toSet();
  final visible = data.competitions
      .where((competition) => visibleCompetitionIds.contains(competition.id))
      .toList();

  final userCountry = selectedCountry ?? detectedCountry;
  final custom = orderMode == CompetitionOrderMode.personalized;
  // A stale pin (no longer followed) never reorders anything.
  final pins = {
    if (custom)
      for (var i = 0; i < pinnedCompetitionIds.length; i++)
        if (follows.contains('competition:${pinnedCompetitionIds[i]}'))
          pinnedCompetitionIds[i]: i,
  };
  return sortCompetitionsByFeedPriority(
    visible,
    follows: follows,
    userCountry: userCountry,
    pins: pins,
  );
}

class MatchesScreen extends ConsumerStatefulWidget {
  const MatchesScreen({super.key, this.now = costaRicaNow});

  final DateTime Function() now;

  @override
  ConsumerState<MatchesScreen> createState() => _MatchesScreenState();
}

class _MatchesScreenState extends ConsumerState<MatchesScreen>
    with SingleTickerProviderStateMixin {
  DateTime? date;
  String filter = 'Todos';
  // Competitions collapsed by the user in this session (headers stay).
  final Set<String> _collapsed = <String>{};

  // Day change transition: the same list slides in from the side the new day
  // comes from. The list is never rebuilt under a new key (scroll, refresh
  // and in-flight reads are untouched) and nothing is shown twice.
  late final AnimationController _dayTransition = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: 1,
  );
  // +1: a later day comes from the right; -1: an earlier day from the left.
  int _dayDirection = 1;
  // "Today" of the feed being shown (the demo feed has its own).
  DateTime? _today;

  @override
  void dispose() {
    _dayTransition.dispose();
    super.dispose();
  }

  void _setDate(DateTime value) {
    final today = _today ?? DateUtils.dateOnly(widget.now());
    // With no date picked yet the feed shows its own "today" (the anchor).
    final previous = DateUtils.dateOnly(date ?? today);
    final next = DateUtils.dateOnly(value);
    setState(() {
      date = value;
      _collapsed.clear();
      if (next != previous) _dayDirection = next.isAfter(previous) ? 1 : -1;
      // #168: "En vivo" only makes sense today. On any other day it would
      // leave an empty screen although that day has matches.
      filter = matchFilterForDate(filter, next, today);
    });
    if (next == previous) return;
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _dayTransition.value = 1;
    } else {
      _dayTransition.forward(from: 0);
    }
  }

  void _toggleCollapsed(String competitionId) => setState(() {
    if (!_collapsed.remove(competitionId)) _collapsed.add(competitionId);
  });

  Future<void> _pickDate(BuildContext context, DateTime selected) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: selected,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) _setDate(picked);
  }

  Widget _centeredDateOption(int offset, DateTime selected, DateTime today) {
    final candidate = DateUtils.dateOnly(selected.add(Duration(days: offset)));
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.only(right: 6),
        child: _DateOption(
          label: _dateContextLabel(candidate, today),
          date: candidate,
          selected: offset == 0,
          onTap: () => _setDate(candidate),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final requestDate = DateUtils.dateOnly(date ?? widget.now());

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.sports_soccer, color: lime),
            SizedBox(width: 8),
            Text('Fut', style: TextStyle(fontWeight: FontWeight.w900)),
            Text(
              'Beat',
              style: TextStyle(fontWeight: FontWeight.w900, color: lime),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Buscar equipos y jugadores',
            onPressed: () => context.go('/explore'),
            icon: const Icon(Icons.search),
          ),
        ],
      ),
      body: CalendarDataView(
        date: requestDate,
        builder: (data, loading, failed) {
          final anchor = data.demo
              ? DateTime(2026, 9, 15)
              : DateUtils.dateOnly(widget.now());
          final selected = DateUtils.dateOnly(date ?? anchor);
          _today = anchor;
          final effectiveFilter = matchFilterForDate(filter, selected, anchor);
          if (effectiveFilter != filter) {
            // The anchor can roll over at midnight without a date tap. Render
            // coherently now and persist the normalized state after the frame.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              final currentToday = _today ?? DateUtils.dateOnly(widget.now());
              final currentSelected = DateUtils.dateOnly(date ?? currentToday);
              final normalized = matchFilterForDate(
                filter,
                currentSelected,
                currentToday,
              );
              if (normalized != filter) setState(() => filter = normalized);
            });
          }
          final follows =
              ref.watch(followsProvider).asData?.value ?? <String>{};
          final preference = ref.watch(preferenceProvider).asData?.value;
          final games = dedupeFixtures(data.onDate(selected, effectiveFilter));

          final followedGames =
              games
                  .where((match) => _isFollowedTeamMatch(match, follows))
                  .toList()
                ..sort((a, b) => a.startTime.compareTo(b.startTime));
          final followedIds = followedGames.map((match) => match.id).toSet();
          final remainingGames =
              games.where((match) => !followedIds.contains(match.id)).toList()
                ..sort((a, b) => a.startTime.compareTo(b.startTime));

          final remainingByCompetition = <String, List<FootballMatch>>{};
          for (final match in remainingGames) {
            remainingByCompetition
                .putIfAbsent(match.competitionId, () => <FootballMatch>[])
                .add(match);
          }

          final orderedCompetitions = orderMatchCompetitions(
            data: data,
            matches: remainingGames,
            follows: follows,
            selectedCountry: preference?.selectedCountry,
            detectedCountry: preference?.detectedCountry,
            orderMode:
                preference?.competitionOrderMode ??
                CompetitionOrderMode.automatic,
            orderPreference:
                preference?.competitionOrderPreference ??
                CompetitionOrderPreference.countryFirst,
            pinnedCompetitionIds:
                preference?.pinnedCompetitionIds ?? const <String>[],
          );
          final feedItems = <Widget Function()>[];

          void addCompetition(Entity competition) {
            final competitionMatches =
                remainingByCompetition[competition.id] ??
                const <FootballMatch>[];
            if (competitionMatches.isEmpty) return;

            // The live filter always shows its rows.
            final collapsed =
                effectiveFilter != 'En vivo' &&
                _collapsed.contains(competition.id);
            feedItems.add(
              () => _CompetitionHeader(
                competition: competition,
                count: competitionMatches.length,
                liveCount: competitionMatches.where((m) => m.isLive).length,
                collapsed: collapsed,
                onOpen: () => context.push('/competition/${competition.id}'),
                onToggle: () => _toggleCollapsed(competition.id),
                canToggle: effectiveFilter != 'En vivo',
              ),
            );
            if (!collapsed) {
              for (final match in competitionMatches) {
                feedItems.add(() => MatchCard(match, data));
              }
            }
            feedItems.add(() => const SizedBox(height: 8));
          }

          feedItems
            ..add(
              () => const Text(
                'EL LATIDO DEL FÚTBOL',
                style: TextStyle(color: muted, fontSize: 10, letterSpacing: 3),
              ),
            )
            ..add(() => const SizedBox(height: 20));

          if (data.demo) {
            feedItems.add(() => const DemoNotice());
          }

          feedItems
            ..add(
              () => Row(
                children: [
                  for (final offset in [-1, 0, 1])
                    _centeredDateOption(offset, selected, anchor),
                  SizedBox(
                    width: 46,
                    height: 64,
                    child: IconButton.filledTonal(
                      tooltip: 'Elegir otra fecha',
                      onPressed: () => _pickDate(context, selected),
                      icon: const Icon(Icons.calendar_month_outlined),
                    ),
                  ),
                ],
              ),
            )
            ..add(() => const SizedBox(height: 12))
            ..add(
              () => SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final value in [
                      'Todos',
                      'En vivo',
                      'Próximos',
                      'Finalizados',
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(
                            value,
                            style: TextStyle(
                              color: effectiveFilter == value
                                  ? const Color(0xFF0B1114)
                                  : Colors.white,
                            ),
                          ),
                          selected: effectiveFilter == value,
                          // A non-today date cannot contain an in-progress
                          // match. Keep the option visible for orientation,
                          // but do not allow an artificial empty LIVE view.
                          onSelected: value == 'En vivo' && selected != anchor
                              ? null
                              : (_) => setState(() => filter = value),
                        ),
                      ),
                  ],
                ),
              ),
            )
            ..add(() => const SizedBox(height: 16));

          if (loading) {
            feedItems.add(() => const LinearProgressIndicator());
            if (data.calendarPending) {
              feedItems.add(
                () => const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('Preparando los partidos de esta fecha…'),
                ),
              );
            }
          } else if (failed) {
            feedItems.add(() => const Text('No pudimos cargar esta fecha'));
            feedItems.add(
              () => TextButton(
                onPressed: () =>
                    ref.invalidate(calendarSnapshotProvider(requestDate)),
                child: const Text('Reintentar'),
              ),
            );
          } else if (games.isEmpty) {
            feedItems.add(() => const EmptyState('Sin partidos', ''));
          }

          if (followedGames.isNotEmpty) {
            feedItems.add(() => const _FeedHeading(title: 'FAVORITOS'));
            for (final match in followedGames) {
              feedItems.add(() => MatchCard(match, data));
            }
            feedItems.add(() => const SizedBox(height: 12));
          }

          // Then every competition with its remaining matches. Favourite-team
          // fixtures were removed above, so every canonical match is rendered
          // exactly once.
          for (final competition in orderedCompetitions) {
            addCompetition(competition);
          }

          // Horizontal fling = previous/next day. Vertical scrolling and
          // inner horizontal lists keep their gestures (gesture arena).
          return GestureDetector(
            key: const ValueKey('matches-date-swipe'),
            behavior: HitTestBehavior.translucent,
            onHorizontalDragEnd: (details) {
              final velocity = details.primaryVelocity ?? 0;
              if (velocity.abs() < _dateSwipeMinVelocity) return;
              _setDate(
                DateUtils.dateOnly(
                  selected.add(Duration(days: velocity < 0 ? 1 : -1)),
                ),
              );
            },
            child: AnimatedBuilder(
              animation: _dayTransition,
              builder: (context, child) {
                // Always the same widget shape: the list keeps its element
                // (scroll position, refresh state) while it slides.
                final t = Curves.easeOutCubic.transform(_dayTransition.value);
                return Opacity(
                  opacity: 0.25 + 0.75 * t,
                  child: Transform.translate(
                    offset: Offset((1 - t) * 36 * _dayDirection, 0),
                    child: child,
                  ),
                );
              },
              child: RefreshIndicator(
                onRefresh: () async {
                  final repository = ref.read(repositoryProvider);
                  if (repository is ApiRepository) {
                    repository.refreshDate(selected);
                  }
                  ref.invalidate(calendarSnapshotProvider(selected));
                  try {
                    await ref.read(calendarSnapshotProvider(selected).future);
                  } catch (_) {
                    // CalendarDataView exposes the provider error and retry action.
                  }
                },
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) => feedItems[index](),
                          childCount: feedItems.length,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Logical px/s: a deliberate fling, not a slightly diagonal scroll.
const _dateSwipeMinVelocity = 350.0;

class _DateOption extends StatelessWidget {
  const _DateOption({
    required this.label,
    required this.date,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final DateTime date;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? lime : const Color(0xFF151D20),
    borderRadius: BorderRadius.circular(16),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        height: 64,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: selected ? null : Border.all(color: const Color(0xFF394246)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  color: selected ? const Color(0xFF0B1114) : muted,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                _compactDate(date),
                maxLines: 1,
                style: TextStyle(
                  color: selected ? const Color(0xFF0B1114) : Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _FeedHeading extends StatelessWidget {
  const _FeedHeading({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6, bottom: 14),
    child: Row(
      children: [
        const Icon(Icons.star_rounded, color: lime, size: 18),
        const SizedBox(width: 6),
        Text(
          title,
          style: const TextStyle(
            color: lime,
            fontSize: 13,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.8,
          ),
        ),
      ],
    ),
  );
}

class _CompetitionHeader extends StatelessWidget {
  const _CompetitionHeader({
    required this.competition,
    required this.count,
    required this.liveCount,
    required this.collapsed,
    required this.onOpen,
    required this.onToggle,
    required this.canToggle,
  });

  final Entity competition;
  final int count;
  final int liveCount;
  final bool collapsed;
  final VoidCallback onOpen;
  final VoidCallback onToggle;
  final bool canToggle;

  // Same visibility rule as before (a provider country), localized text only.
  String? get region =>
      competition.country.isEmpty ? null : entityCountryLabel(competition);

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 4, bottom: 8),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: BoxDecoration(
      color: const Color(0xFF151D20),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFF2A3438)),
    ),
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              key: ValueKey('competition-open-${competition.id}'),
              onTap: onOpen,
              borderRadius: BorderRadius.circular(10),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(
                  children: [
                    EntityAvatar(competition, size: 32),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            competition.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                          ),
                          if (region case final label?)
                            Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: muted,
                                fontSize: 11,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (collapsed && liveCount > 0) ...[
            Text(
              key: ValueKey('competition-live-${competition.id}'),
              '$liveCount en vivo',
              style: const TextStyle(
                color: lime,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Text(
            '$count',
            key: ValueKey('competition-count-${competition.id}'),
            style: const TextStyle(color: muted, fontWeight: FontWeight.w700),
          ),
          if (canToggle)
            Semantics(
              expanded: !collapsed,
              button: true,
              enabled: true,
              excludeSemantics: true,
              onTap: onToggle,
              label: collapsed
                  ? 'Mostrar partidos de ${competition.name}'
                  : 'Ocultar partidos de ${competition.name}',
              child: IconButton(
                key: ValueKey('competition-toggle-${competition.id}'),
                tooltip: collapsed
                    ? 'Mostrar partidos de ${competition.name}'
                    : 'Ocultar partidos de ${competition.name}',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: onToggle,
                icon: Icon(
                  collapsed ? Icons.expand_more : Icons.expand_less,
                  color: muted,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// One-line feed row. Same data rules as [MatchCard] (showKickoff/statusLabel).
class FeedMatchRow extends StatelessWidget {
  const FeedMatchRow(this.match, this.data, {this.caption, super.key});

  final FootballMatch match;
  final Snapshot data;

  /// Optional small context line for compact-row reuse outside this feed.
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final home = data.team(match.homeId)!;
    final away = data.team(match.awayId)!;
    final latestEvent = match.latestEvent;
    // Past kickoff with no evidence of play: never an upcoming kickoff.
    final unconfirmed = match.isAwaitingUpdate && !match.hasPlayedEvidence;
    final status = unconfirmed ? 'Por confirmar' : match.statusLabel;
    final centre = unconfirmed
        ? '—'
        : match.showKickoff
        ? localTime(context, match.startTime)
        : match.score;
    void open() =>
        context.push('/match/${match.id}', extra: data.forMatch(match.id));
    const nameStyle = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600);
    final second = <Widget>[
      if (caption != null)
        Text(
          caption!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: muted, fontSize: 10),
        ),
      if (match.isLive && latestEvent != null)
        Text(
          'Último: ${eventMinuteLabel(latestEvent)} · '
          '${_feedEventLabel(latestEvent['type'] as String? ?? '')}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: lime,
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
          ),
        ),
    ];
    final label = StringBuffer(
      '${home.displayName} contra ${away.displayName}, $centre',
    );
    if (status.isNotEmpty) label.write(', $status');
    if (caption != null) label.write(', $caption');
    if (match.isLive && latestEvent != null) {
      label.write(
        ', Último: ${eventMinuteLabel(latestEvent)} · '
        '${_feedEventLabel(latestEvent['type'] as String? ?? '')}',
      );
    }
    // The row opens the match; the star (a sibling, never nested) follows it.
    return Row(
      children: [
        Expanded(
          child: Semantics(
            button: true,
            excludeSemantics: true,
            label: label.toString(),
            onTap: open,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: open,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          EntityAvatar(home, size: 22),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              home.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: nameStyle,
                            ),
                          ),
                          SizedBox(
                            width: 84,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    centre,
                                    maxLines: 1,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                if (status.isNotEmpty)
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      status,
                                      maxLines: 1,
                                      style: TextStyle(
                                        color: match.isLive ? lime : muted,
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Text(
                              away.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.right,
                              style: nameStyle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          EntityAvatar(away, size: 22),
                        ],
                      ),
                      for (final line in second)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: line,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        FollowButton(
          'match',
          match.id,
          key: ValueKey('feed-follow-${match.id}'),
          label: '${home.displayName} contra ${away.displayName}',
          compact: true,
        ),
      ],
    );
  }
}

class MatchCard extends StatelessWidget {
  const MatchCard(this.match, this.data, {super.key});

  final FootballMatch match;
  final Snapshot data;

  @override
  Widget build(BuildContext context) {
    final home = data.team(match.homeId)!;
    final away = data.team(match.awayId)!;
    final latestEvent = match.latestEvent;
    // A scheduled row whose kickoff already passed without any evidence of
    // play is not allowed to masquerade as an upcoming match.
    final unconfirmed = match.isAwaitingUpdate && !match.hasPlayedEvidence;
    final status = unconfirmed ? 'Por confirmar' : match.statusLabel;
    final centre = unconfirmed
        ? '—'
        : match.showKickoff
        ? localTime(context, match.startTime)
        : match.score;
    void open() =>
        context.push('/match/${match.id}', extra: data.forMatch(match.id));
    final semanticLabel = [
      '${home.displayName} contra ${away.displayName}',
      centre,
      if (status.isNotEmpty) status,
    ].join(', ');

    return Card(
      key: ValueKey('match-card-${match.id}'),
      child: Semantics(
        key: ValueKey('match-card-action-${match.id}'),
        container: true,
        button: true,
        label: semanticLabel,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: open,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 18),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: status.isEmpty
                          ? const SizedBox.shrink()
                          : Text(
                              status.toUpperCase(),
                              style: TextStyle(
                                color: match.isLive ? lime : muted,
                                fontSize: 10,
                                letterSpacing: 1,
                              ),
                            ),
                    ),
                    FollowButton(
                      'match',
                      match.id,
                      key: ValueKey('feed-follow-${match.id}'),
                      label: '${home.displayName} contra ${away.displayName}',
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        children: [
                          EntityAvatar(home),
                          const SizedBox(height: 9),
                          Text(
                            home.displayName,
                            textAlign: TextAlign.center,
                            // Very long names never stretch the card; the
                            // full name stays in the card's semantic label.
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          Text(
                            centre,
                            style: TextStyle(
                              fontSize: unconfirmed
                                  ? 30
                                  : match.showKickoff
                                  ? 21
                                  : 30,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            unconfirmed
                                ? 'Ver partido'
                                : match.showKickoff
                                ? 'Hora Costa Rica'
                                : 'Ver partido',
                            style: const TextStyle(fontSize: 10, color: muted),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          EntityAvatar(away),
                          const SizedBox(height: 9),
                          Text(
                            away.displayName,
                            textAlign: TextAlign.center,
                            // Very long names never stretch the card; the
                            // full name stays in the card's semantic label.
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (match.isLive && latestEvent != null) ...[
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: lime.withValues(alpha: .07),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'Último: ${eventMinuteLabel(latestEvent)} · '
                      '${_feedEventLabel(latestEvent['type'] as String? ?? '')}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: lime,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

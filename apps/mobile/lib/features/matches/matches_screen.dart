import 'package:flutter/material.dart';

import '../../shared/live_freshness_notice.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ads.dart';
import '../../core/interests.dart';
import '../../core/database.dart';
import '../../core/load_errors.dart';
import '../../core/models.dart';
import '../../core/match_prefetch_plan.dart';
import '../../core/providers.dart';
import '../../core/relevance.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';

/// "Favoritos" is only for matches of a favourite TEAM (never a followed
/// league, never a single followed match: those only mark the follow).
bool isFollowedTeamMatch(
  FootballMatch match,
  Set<String> follows, {
  String Function(String)? resolve,
}) =>
    follows.contains('team:${resolve?.call(match.homeId) ?? match.homeId}') ||
    follows.contains('team:${resolve?.call(match.awayId) ?? match.awayId}');

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
bool _sameFixture(
  FootballMatch a,
  FootballMatch b,
  String Function(String) resolve,
) {
  final competition = resolve(a.competitionId);
  final home = resolve(a.homeId);
  final away = resolve(a.awayId);
  if (competition.isEmpty ||
      competition != resolve(b.competitionId) ||
      home.isEmpty ||
      home == away ||
      home != resolve(b.homeId) ||
      away != resolve(b.awayId)) {
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
/// daily feed groups each canonical fixture once per section: the same canonical
/// match id, or two match entities of one fixture (see [_sameFixture]). The
/// best twin stays: finished > live > played evidence > scheduled > called
/// off, then the lower id. The order of the surviving matches is preserved.
List<FootballMatch> dedupeFixtures(
  Iterable<FootballMatch> matches, {
  String Function(String)? resolve,
}) {
  final resolveId = resolve ?? (String id) => id;
  // A snapshot may contain several revisions of the same canonical id. Keep
  // its strongest evidence; for equal evidence, use the last row just as
  // Snapshot.match(id) does, so a corrected score cannot differ by screen.
  final byId = <String, FootballMatch>{};
  for (final match in matches) {
    final previous = byId[match.id];
    if (previous == null || _fixtureRank(match) <= _fixtureRank(previous)) {
      byId[match.id] = match;
    }
  }
  final kept = <FootballMatch>[];
  // Only equal canonical competition/home/away triplets can be twins. Keep
  // their indexes so unrelated fixtures never enter the comparison scan,
  // while replacements preserve the original visible position.
  final candidates = <(String, String, String), List<int>>{};
  for (final match in byId.values) {
    final key = (
      resolveId(match.competitionId),
      resolveId(match.homeId),
      resolveId(match.awayId),
    );
    final indexes = candidates.putIfAbsent(key, () => <int>[]);
    final twin = indexes
        .where((index) => _sameFixture(match, kept[index], resolveId))
        .firstOrNull;
    if (twin == null) {
      indexes.add(kept.length);
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

/// Stable chronological feed order even if a snapshot returns tied kickoffs
/// in a different order after revalidation or a Realtime update.
int compareFeedKickoffs(FootballMatch a, FootballMatch b) {
  final byTime = a.startTime.compareTo(b.startTime);
  return byTime != 0 ? byTime : a.id.compareTo(b.id);
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

/// At most this many ad slots in one day's feed.
const feedAdMaxSlots = 5;

/// Where the Partidos feed may show an ad, as the number of complete
/// competition groups before each slot (0 = right after the FAVORITOS
/// block). With favourites: after them, then after groups 3, 7, 11, 15.
/// Without: after groups 1, 3, 6, 9, 12 (18 is the next candidate, but the
/// daily cap is already reached). A slot always has feed content
/// after it (never at the end, never two in a row, never inside a group),
/// at most [feedAdMaxSlots], and none in the LIVE view. Whether a slot
/// shows anything is [adsAllowedProvider]'s call (never for Premium).
List<int> feedAdSlots({
  required bool favorites,
  required int groups,
  required String filter,
}) {
  if (filter == 'En vivo') return const [];
  final slots = <int>[];
  final candidates = favorites
      ? const [0, 3, 7, 11, 15]
      : const [1, 3, 6, 9, 12, 18];
  for (final after in candidates) {
    if (slots.length == feedAdMaxSlots) break;
    // Never reserve an ad at the end of the feed.
    if (after < groups) slots.add(after);
  }
  return slots;
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
      .map((match) => data.resolveEntityId(match.competitionId))
      .toSet();
  final visibleById = <String, Entity>{};
  for (final competition in data.competitions) {
    final id = data.resolveEntityId(competition.id);
    if (!visibleCompetitionIds.contains(id)) continue;
    final canonical = data.competition(competition.id) ?? competition;
    visibleById.putIfAbsent(
      id,
      () => canonical.id == id
          ? canonical
          : Entity({...canonical.json, 'id': id}),
    );
  }
  final visible = visibleById.values.toList();

  final userCountry = selectedCountry ?? detectedCountry;
  final custom = orderMode == CompetitionOrderMode.personalized;
  // A stale pin (no longer followed) never reorders anything.
  final pins = <String, int>{};
  if (custom) {
    for (var i = 0; i < pinnedCompetitionIds.length; i++) {
      final id = data.resolveEntityId(pinnedCompetitionIds[i]);
      if (follows.contains('competition:$id')) {
        // Keep the first saved position when alias and canonical IDs coexist.
        pins.putIfAbsent(id, () => i);
      }
    }
  }
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
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  DateTime? date;
  String filter = 'Todos';
  bool _retrying = false;
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
  bool _sportsActive = true;
  bool _prefetchQueued = false;
  bool _prefetchRunning = false;
  int _prefetchGeneration = 0;
  int _prefetchRemaining = 8;
  final Set<String> _prefetchAttempted = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (active == _sportsActive) return;
    _sportsActive = active;
    if (!active) {
      _prefetchGeneration++;
    } else if (mounted) {
      setState(() {});
    }
  }

  void _warmRelevantMatches(
    Snapshot data,
    List<FootballMatch> games,
    Set<String> follows,
    String? country,
  ) {
    if (data.demo ||
        !_sportsActive ||
        _prefetchRunning ||
        _prefetchQueued ||
        _prefetchRemaining <= 0) {
      return;
    }
    final plan = MatchPrefetchPlan.build(
      // A finished fixture can be followed too. Its persisted Match Center
      // detail should paint from disk as promptly as a live fixture.
      matches: games
          .where(
            (match) => match.isUpcoming || match.isLive || match.isFinished,
          )
          .map(
            // Only normalize the planning projection: the disk key remains
            // the canonical match ID and the displayed fixture is untouched.
            (match) => FootballMatch({
              ...match.json,
              'competitionId': data.resolveEntityId(match.competitionId),
              'homeTeamId': data.resolveEntityId(match.homeId),
              'awayTeamId': data.resolveEntityId(match.awayId),
            }),
          ),
      follows: follows,
      selectedCountry: country,
      competitions: {
        for (final entry in data.competitions)
          data.resolveEntityId(entry.id): data.competition(entry.id) ?? entry,
      },
      maxMatches: 8,
    ).excluding(_prefetchAttempted);
    if (plan.matchIds.isEmpty) return;
    final queuedGeneration = _prefetchGeneration;
    _prefetchQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _prefetchQueued = false;
      if (!mounted || !_sportsActive || _prefetchRunning) return;
      if (queuedGeneration != _prefetchGeneration) {
        // A date/lifecycle change invalidated this plan before it started.
        // Rebuild once so the newest date can queue its own plan.
        setState(() {});
        return;
      }
      final repository = ref.read(repositoryProvider);
      if (repository is! ApiRepository) return;
      final memory = ref.read(matchDetailMemoryProvider);
      final generation = ++_prefetchGeneration;
      _prefetchRunning = true;
      try {
        await runMatchPrefetch(
          plan,
          maxRequests: _prefetchRemaining < 2 ? _prefetchRemaining : 2,
          isActive: () =>
              mounted && _sportsActive && generation == _prefetchGeneration,
          fetch: (id) async {
            if (!_prefetchAttempted.add(id)) return;
            _prefetchRemaining--;
            repository.diagnostics?.record(
              '/v1/match-detail',
              'prefetchAttempt',
            );
            if (memory[id]?.available == true) {
              repository.diagnostics?.record(
                '/v1/match-detail',
                'prefetchMemoryHit',
              );
              return;
            }
            // A match-detail HTTP read can register provider work even with
            // request=0. Warm only previously persisted data here; the user
            // opening Match Center owns the explicit remote demand.
            try {
              final detail = await repository.readStoredMatchDetail(id);
              repository.diagnostics?.record(
                '/v1/match-detail',
                detail?.available == true
                    ? 'prefetchDiskHit'
                    : 'prefetchDiskMiss',
              );
              if (detail?.available == true &&
                  mounted &&
                  _sportsActive &&
                  generation == _prefetchGeneration &&
                  memory[id] == null) {
                memory[id] = detail!;
                while (memory.length > matchDetailMemoryLimit) {
                  memory.remove(memory.keys.first);
                }
              }
            } finally {
              if ((!mounted ||
                      !_sportsActive ||
                      generation != _prefetchGeneration) &&
                  memory[id]?.available != true) {
                // Cancellation did not warm this ID. Let the next active
                // plan retry it within the remaining session read budget.
                _prefetchAttempted.remove(id);
              }
            }
          },
        );
      } finally {
        _prefetchRunning = false;
        // Continue the next bounded disk batch while this visible session
        // still has budget. No unrelated rebuild should be required to warm
        // the remaining favorite fixtures. A changed generation replans first.
        if (mounted &&
            _sportsActive &&
            (generation != _prefetchGeneration || _prefetchRemaining > 0)) {
          setState(() {});
        }
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _prefetchGeneration++;
    _dayTransition.dispose();
    super.dispose();
  }

  void _setDate(DateTime value) {
    final today = _today ?? DateUtils.dateOnly(widget.now());
    // With no date picked yet the feed shows its own "today" (the anchor).
    final previous = DateUtils.dateOnly(date ?? today);
    final next = DateUtils.dateOnly(value);
    if (next != previous) {
      _prefetchGeneration++;
    }
    setState(() {
      date = value;
      if (next != previous) {
        _collapsed.clear();
        _dayDirection = next.isAfter(previous) ? 1 : -1;
      }
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

  Future<void> _retry(DateTime value) async {
    if (_retrying) return;
    setState(() => _retrying = true);
    ref.invalidate(calendarSnapshotProvider(value));
    try {
      await ref.read(calendarSnapshotProvider(value).future);
    } catch (_) {
      // The same recoverable state remains visible.
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

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
          final allGames = dedupeFixtures(
            data.onDate(selected, 'Todos'),
            resolve: data.resolveEntityId,
          );
          _warmRelevantMatches(
            data,
            allGames,
            follows,
            // A detected country alone must not trigger detail reads; an
            // explicit selection or follow is required for warming.
            preference?.selectedCountry,
          );
          // Filter after deduplication so a stale scheduled/LIVE twin cannot
          // reappear in a tab when its final result won in Todos.
          final games = allGames
              .where(
                (match) => switch (effectiveFilter) {
                  'En vivo' => match.isLive,
                  'Próximos' => match.isUpcoming,
                  'Finalizados' => match.isFinished,
                  _ => true,
                },
              )
              .toList();

          final followedGames =
              games
                  .where(
                    (match) => isFollowedTeamMatch(
                      match,
                      follows,
                      resolve: data.resolveEntityId,
                    ),
                  )
                  .toList()
                ..sort(compareFeedKickoffs);
          // Favorites highlight canonical fixtures without removing them from
          // their leagues. The day fixtures were deduplicated before grouping.
          final regularGames = [...games]..sort(compareFeedKickoffs);

          final regularByCompetition = <String, List<FootballMatch>>{};
          for (final match in regularGames) {
            regularByCompetition
                .putIfAbsent(
                  data.resolveEntityId(match.competitionId),
                  () => <FootballMatch>[],
                )
                .add(match);
          }

          final orderedCompetitions = orderMatchCompetitions(
            data: data,
            matches: regularGames,
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

          // Resolve every regular block and its ad cadence before creating
          // any section. Cadence decides which section owns an ad; the
          // section owns the group/ad/next-section layout.
          final competitionById = {
            for (final competition in orderedCompetitions)
              competition.id: competition,
          };
          final visibleCompetitions = orderedCompetitions
              .where(
                (competition) =>
                    (regularByCompetition[competition.id]?.isNotEmpty ?? false),
              )
              .toList(growable: false);
          final plannedAdSlots = feedAdSlots(
            favorites: followedGames.isNotEmpty,
            groups: visibleCompetitions.length,
            filter: effectiveFilter,
          );
          final feedItems = <Widget Function()>[];

          AdSlot? adAfter(int ordinal) {
            final slotIndex = plannedAdSlots.indexOf(ordinal);
            if (slotIndex < 0) return null;
            final day = requestDate.toIso8601String().substring(0, 10);
            return AdSlot(
              AdPlacement.matchesFeed,
              key: ValueKey('feed-ad-$day-$slotIndex'),
            );
          }

          void addCompetition(Entity competition, int ordinal) {
            final competitionMatches =
                regularByCompetition[competition.id] ?? const <FootballMatch>[];
            if (competitionMatches.isEmpty) return;

            // The live filter always shows its rows.
            final collapseKey = 'competition:${competition.id}';
            final collapsed =
                effectiveFilter != 'En vivo' &&
                _collapsed.contains(collapseKey);
            feedItems.add(
              () => CompetitionFeedSection(
                key: ValueKey('feed-section-competition-${competition.id}'),
                group: CompetitionMatchGroupCard(
                  scope: 'competition',
                  competition: competition,
                  matches: competitionMatches,
                  data: data,
                  collapsed: collapsed,
                  onOpen: () => context.push('/competition/${competition.id}'),
                  onToggle: () => _toggleCollapsed(collapseKey),
                  canToggle: effectiveFilter != 'En vivo',
                ),
                ad: adAfter(ordinal),
              ),
            );
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

          if (data.stale && allGames.isNotEmpty && !loading && !failed) {
            feedItems.add(
              () =>
                  const _SavedDataNotice(message: 'Mostrando datos guardados.'),
            );
          }

          if (loading) {
            if (data.calendarPending) {
              feedItems.add(
                () => const _MatchesStatusCard(
                  key: ValueKey('matches-calendar-pending'),
                  icon: Icons.calendar_month_outlined,
                  title: 'Preparando los partidos de esta fecha…',
                  message: 'El calendario estará disponible en breve.',
                  loading: true,
                ),
              );
            } else {
              feedItems.add(() => const _MatchesFeedSkeleton());
            }
          } else if (failed) {
            final error = ref
                .read(effectiveCalendarSnapshotProvider(requestDate))
                .error;
            feedItems.add(
              () => _MatchesStatusCard(
                key: const ValueKey('matches-load-error'),
                icon: classifyLoadError(error) == LoadFailure.offline
                    ? Icons.cloud_off_outlined
                    : Icons.sync_problem_outlined,
                title: classifyLoadError(error) == LoadFailure.offline
                    ? 'Sin conexión.'
                    : 'No pudimos cargar los partidos.',
                message: 'Puedes cambiar de fecha o intentarlo nuevamente.',
                actionLabel: _retrying ? 'Reintentando…' : 'Reintentar',
                onAction: _retrying ? null : () => _retry(requestDate),
              ),
            );
          } else if (allGames.isEmpty &&
              (data.stale || data.coverage?['partial'] == true)) {
            feedItems.add(
              () => _MatchesStatusCard(
                key: ValueKey(
                  data.stale ? 'matches-stale-empty' : 'matches-partial-empty',
                ),
                icon: Icons.cloud_sync_outlined,
                title: 'No pudimos confirmar los partidos de este día.',
                message: data.stale
                    ? 'La información guardada puede estar incompleta.'
                    : 'La cobertura del calendario todavía es parcial.',
                actionLabel: _retrying ? 'Reintentando…' : 'Reintentar',
                onAction: _retrying ? null : () => _retry(requestDate),
              ),
            );
          } else if (allGames.isEmpty) {
            feedItems.add(
              () => _MatchesStatusCard(
                key: const ValueKey('matches-empty-day'),
                icon: Icons.event_busy_outlined,
                title: 'No hay partidos para este día.',
                message: selected == anchor
                    ? 'Prueba otra fecha para consultar el calendario.'
                    : 'Puedes elegir otra fecha o volver a Hoy.',
                actionLabel: selected == anchor ? null : 'Volver a Hoy',
                onAction: selected == anchor ? null : () => _setDate(anchor),
              ),
            );
          } else if (games.isEmpty) {
            feedItems.add(
              () => _MatchesStatusCard(
                key: ValueKey('matches-empty-filter-$effectiveFilter'),
                icon: effectiveFilter == 'En vivo'
                    ? Icons.sensors_outlined
                    : Icons.filter_alt_off_outlined,
                title: data.stale
                    ? 'No hay partidos guardados para este filtro.'
                    : data.coverage?['partial'] == true
                    ? 'No pudimos confirmar partidos para este filtro.'
                    : switch (effectiveFilter) {
                        'En vivo' => 'No hay partidos en vivo ahora.',
                        'Próximos' => 'No hay próximos partidos.',
                        'Finalizados' => 'No hay partidos finalizados.',
                        _ => 'No hay partidos para este filtro.',
                      },
                message: data.stale
                    ? 'Puedes ver los partidos guardados en Todos.'
                    : data.coverage?['partial'] == true
                    ? 'La cobertura del calendario todavía es parcial.'
                    : 'Los partidos del día siguen disponibles en Todos.',
                actionLabel: 'Ver todos',
                onAction: () => setState(() => filter = 'Todos'),
              ),
            );
          }

          if (followedGames.isNotEmpty) {
            feedItems.add(() => const _FeedHeading(title: 'FAVORITOS'));
            final favoriteGroups = <String, List<FootballMatch>>{};
            for (final match in followedGames) {
              favoriteGroups
                  .putIfAbsent(
                    data.resolveEntityId(match.competitionId),
                    () => <FootballMatch>[],
                  )
                  .add(match);
            }
            final favoriteEntries = favoriteGroups.entries
                .where((entry) => competitionById.containsKey(entry.key))
                .toList();
            for (final (index, entry) in favoriteEntries.indexed) {
              final competition = competitionById[entry.key];
              if (competition == null) continue;
              final collapseKey = 'favorite:${competition.id}';
              final collapsed =
                  effectiveFilter != 'En vivo' &&
                  _collapsed.contains(collapseKey);
              feedItems.add(
                () => CompetitionFeedSection(
                  key: ValueKey('feed-section-favorite-${competition.id}'),
                  group: CompetitionMatchGroupCard(
                    scope: 'favorite',
                    competition: competition,
                    matches: entry.value,
                    data: data,
                    collapsed: collapsed,
                    onOpen: () =>
                        context.push('/competition/${competition.id}'),
                    onToggle: () => _toggleCollapsed(collapseKey),
                    canToggle: effectiveFilter != 'En vivo',
                  ),
                  ad: index == favoriteEntries.length - 1 ? adAfter(0) : null,
                ),
              );
            }
          }

          // All matches, including favorites, stay visible in their competition.
          for (final (index, competition) in visibleCompetitions.indexed) {
            final ordinal = index + 1;
            addCompetition(competition, ordinal);
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

class _MatchesFeedSkeleton extends StatelessWidget {
  const _MatchesFeedSkeleton();

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Cargando partidos',
    liveRegion: true,
    child: ExcludeSemantics(
      child: Container(
        key: const ValueKey('matches-loading-skeleton'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: panel,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF263238)),
        ),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SkeletonLine(width: 150, height: 16),
            SizedBox(height: 14),
            _SkeletonMatchRow(),
            Divider(height: 22),
            _SkeletonMatchRow(),
            Divider(height: 22),
            _SkeletonMatchRow(),
          ],
        ),
      ),
    ),
  );
}

class _SkeletonMatchRow extends StatelessWidget {
  const _SkeletonMatchRow();

  @override
  Widget build(BuildContext context) => const Row(
    children: [
      _SkeletonLine(width: 36, height: 36, radius: 18),
      SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SkeletonLine(width: 170, height: 12),
            SizedBox(height: 8),
            _SkeletonLine(width: 110, height: 10),
          ],
        ),
      ),
      SizedBox(width: 10),
      _SkeletonLine(width: 44, height: 22),
    ],
  );
}

class _SkeletonLine extends StatelessWidget {
  const _SkeletonLine({
    required this.width,
    required this.height,
    this.radius = 6,
  });

  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: const Color(0xFF263238),
      borderRadius: BorderRadius.circular(radius),
    ),
  );
}

class _MatchesStatusCard extends StatelessWidget {
  const _MatchesStatusCard({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.loading = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool loading;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF263238)),
      ),
      child: Column(
        children: [
          Icon(icon, color: lime, size: 38),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 7),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: muted, height: 1.4),
          ),
          if (loading) ...[
            const SizedBox(height: 18),
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ],
          if (actionLabel != null) ...[
            const SizedBox(height: 18),
            FilledButton.tonal(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    ),
  );
}

class _SavedDataNotice extends StatelessWidget {
  const _SavedDataNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      key: const ValueKey('matches-saved-data-notice'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2429),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_done_outlined, color: muted, size: 18),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: muted, fontSize: 13),
            ),
          ),
        ],
      ),
    ),
  );
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

/// A structural feed unit: group, optional ad, then the transition to the
/// next unit. The ad is a sibling of the card, never part of its surface.
class CompetitionFeedSection extends StatelessWidget {
  const CompetitionFeedSection({required this.group, this.ad, super.key});

  final Widget group;
  final Widget? ad;

  @override
  Widget build(BuildContext context) => Column(
    key: const ValueKey('competition-feed-section-layout'),
    mainAxisSize: MainAxisSize.min,
    children: [
      group,
      ?ad,
      const SizedBox(
        key: ValueKey('competition-feed-section-spacing'),
        height: 12,
      ),
    ],
  );
}

/// A complete competition block: identity, optional subgroup labels and every
/// surviving match row.
class CompetitionMatchGroupCard extends StatelessWidget {
  const CompetitionMatchGroupCard({
    required this.scope,
    required this.competition,
    required this.matches,
    required this.data,
    required this.collapsed,
    required this.onOpen,
    required this.onToggle,
    required this.canToggle,
    super.key,
  });

  final String scope;
  final Entity competition;
  final List<FootballMatch> matches;
  final Snapshot data;
  final bool collapsed;
  final VoidCallback onOpen;
  final VoidCallback onToggle;
  final bool canToggle;

  // Same visibility rule as before (a provider country), localized text only.
  String? get region =>
      competition.country.isEmpty ? null : entityCountryLabel(competition);

  String get _keyPrefix => scope == 'competition' ? 'competition' : scope;

  @override
  Widget build(BuildContext context) {
    final displayCompetition = entityWithCanonicalMedia(
      data,
      competition,
      data.competitions,
    );
    final liveCount = matches.where((match) => match.isLive).length;
    return Card(
      key: ValueKey('competition-group-$scope-${competition.id}'),
      clipBehavior: Clip.antiAlias,
      color: const Color(0xFF151D20),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF2A3438)),
      ),
      margin: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      key: ValueKey('$_keyPrefix-open-${competition.id}'),
                      onTap: onOpen,
                      borderRadius: BorderRadius.circular(10),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: Row(
                          children: [
                            SizedBox(
                              key: ValueKey(
                                'competition-logo-${competition.id}',
                              ),
                              child: EntityAvatar(displayCompetition, size: 36),
                            ),
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
                      key: ValueKey('$_keyPrefix-live-${competition.id}'),
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
                    '${matches.length}',
                    key: ValueKey('$_keyPrefix-count-${competition.id}'),
                    style: const TextStyle(
                      color: muted,
                      fontWeight: FontWeight.w700,
                    ),
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
                        key: ValueKey('$_keyPrefix-toggle-${competition.id}'),
                        tooltip: collapsed
                            ? 'Mostrar partidos de ${competition.name}'
                            : 'Ocultar partidos de ${competition.name}',
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
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
          ),
          if (!collapsed) ...[
            const Divider(height: 1, color: Color(0xFF2A3438)),
            _CompetitionMatchRows(matches: matches, data: data),
          ],
        ],
      ),
    );
  }
}

class _CompetitionMatchRows extends StatelessWidget {
  const _CompetitionMatchRows({required this.matches, required this.data});

  final List<FootballMatch> matches;
  final Snapshot data;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    String? previousSubgroup;
    for (final (index, match) in matches.indexed) {
      final subgroup = competitionMatchSubgroupLabel(match);
      if (subgroup != null && subgroup != previousSubgroup) {
        if (children.isNotEmpty) {
          children.add(const Divider(height: 8, color: Color(0xFF263034)));
        }
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                subgroup,
                key: ValueKey('match-subgroup-${match.id}'),
                style: const TextStyle(
                  color: muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ),
        );
      } else if (index > 0) {
        children.add(const Divider(height: 1, color: Color(0xFF263034)));
      }
      children.add(
        FeedMatchRow(match, data, key: ValueKey('match-row-${match.id}')),
      );
      previousSubgroup = subgroup;
    }
    return Column(mainAxisSize: MainAxisSize.min, children: children);
  }
}

/// Returns a subgroup only when the provider supplied explicit, readable
/// evidence. Unknown or ambiguous values deliberately fail closed.
String? competitionMatchSubgroupLabel(FootballMatch match) {
  String? textFor(String key) {
    final value = match.json[key];
    if (value is! String) return null;
    final text = value.trim();
    return text.isEmpty ? null : text;
  }

  for (final key in const ['groupName', 'subgroup']) {
    final value = textFor(key);
    if (value != null) return value;
  }
  final group = textFor('group');
  if (group != null) {
    final normalized = group.toLowerCase();
    return normalized.startsWith('group') || normalized.startsWith('grupo')
        ? group
        : 'Grupo $group';
  }
  for (final key in const ['stage', 'round']) {
    final value = textFor(key);
    if (value == null) continue;
    final normalized = value.toLowerCase();
    if (normalized.startsWith('group') ||
        normalized.startsWith('grupo') ||
        normalized.startsWith('jornada') ||
        normalized.startsWith('matchday') ||
        normalized.startsWith('round')) {
      return value;
    }
  }
  return null;
}

/// Group-aware wrapper around the approved, full-size match card. The wrapper
/// keeps stable feed keys/tests while [MatchCard] remains the single visual
/// implementation used by grouped and profile feeds.
class FeedMatchRow extends StatelessWidget {
  const FeedMatchRow(this.match, this.data, {this.caption, super.key});

  final FootballMatch match;
  final Snapshot data;

  /// Optional small context line for compact-row reuse outside this feed.
  final String? caption;

  @override
  Widget build(BuildContext context) => MatchCard(
    match,
    data,
    caption: caption,
    preserveStatusCase: true,
    embeddedInGroup: true,
  );
}

/// Keeps the entity's identity/name but borrows VERIFIED media from its
/// canonical equivalent (or one of its redirected aliases) in this snapshot.
/// This is intentionally URL-agnostic and fails closed when no verified media
/// exists; it only repairs sparse calendar rows from already trusted data.
Entity entityWithCanonicalMedia(
  Snapshot data,
  Entity entity,
  Iterable<Entity> candidates,
) {
  if (entity.imageUrl != null) return entity;
  final canonicalId = data.resolveEntityId(entity.id);
  for (final candidate in candidates) {
    if (candidate.imageUrl == null) continue;
    if (candidate.id != canonicalId &&
        data.resolveEntityId(candidate.id) != canonicalId) {
      continue;
    }
    return Entity({...entity.json, 'media': candidate.json['media']});
  }
  return entity;
}

class MatchCard extends StatelessWidget {
  const MatchCard(
    this.match,
    this.data, {
    this.caption,
    this.preserveStatusCase = false,
    this.embeddedInGroup = false,
    super.key,
  });

  final FootballMatch match;
  final Snapshot data;
  final String? caption;
  final bool preserveStatusCase;
  final bool embeddedInGroup;

  @override
  Widget build(BuildContext context) {
    final home = entityWithCanonicalMedia(
      data,
      data.team(match.homeId)!,
      data.teams,
    );
    final away = entityWithCanonicalMedia(
      data,
      data.team(match.awayId)!,
      data.teams,
    );
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
      color: embeddedInGroup ? Colors.transparent : null,
      surfaceTintColor: embeddedInGroup ? Colors.transparent : null,
      elevation: embeddedInGroup ? 0 : null,
      margin: embeddedInGroup ? EdgeInsets.zero : null,
      shape: embeddedInGroup
          ? const RoundedRectangleBorder(
              borderRadius: BorderRadius.zero,
              side: BorderSide.none,
            )
          : null,
      child: Semantics(
        key: ValueKey('match-card-action-${match.id}'),
        container: true,
        button: true,
        label: semanticLabel,
        child: InkWell(
          borderRadius: embeddedInGroup
              ? BorderRadius.zero
              : BorderRadius.circular(18),
          onTap: open,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 18),
            child: Column(
              children: [
                LiveFreshnessNotice(match),
                Row(
                  children: [
                    Expanded(
                      child: status.isEmpty
                          ? const SizedBox.shrink()
                          : Text(
                              preserveStatusCase
                                  ? status
                                  : status.toUpperCase(),
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
                          SizedBox(
                            key: ValueKey('team-crest-${match.id}-home'),
                            child: EntityAvatar(home),
                          ),
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
                          SizedBox(
                            key: ValueKey('team-crest-${match.id}-away'),
                            child: EntityAvatar(away),
                          ),
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
                if (caption != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    caption!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: muted, fontSize: 11),
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

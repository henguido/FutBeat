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

bool _isFollowedTeamMatch(FootballMatch match, Set<String> follows) =>
    follows.contains('team:${match.homeId}') ||
    follows.contains('team:${match.awayId}');

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

bool _isFollowedCompetition(Entity competition, Set<String> follows) =>
    follows.contains('competition:${competition.id}');

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

/// Orders visible competitions without ever filtering the daily catalog.
///
/// Explicit follows stay first. The remaining competitions are ranked by
/// editorial relevance only. Legacy country preferences never affect this feed.
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

  // Legacy country/preference arguments are intentionally ignored.
  final pins = {
    for (var i = 0; i < pinnedCompetitionIds.length; i++)
      if (follows.contains('competition:${pinnedCompetitionIds[i]}'))
        pinnedCompetitionIds[i]: i,
  };
  final custom = orderMode == CompetitionOrderMode.personalized;
  int group(Entity c) => custom && pins.containsKey(c.id)
      ? 0
      : follows.contains('competition:${c.id}')
      ? 1
      : 2;
  return visible..sort((a, b) {
    final category = group(a).compareTo(group(b));
    if (category != 0) return category;
    if (custom && group(a) == 0) return pins[a.id]!.compareTo(pins[b.id]!);
    final score = competitionImportance(b).compareTo(competitionImportance(a));
    if (score != 0) return score;
    final name = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return name != 0 ? name : a.id.compareTo(b.id);
  });
}

class MatchesScreen extends ConsumerStatefulWidget {
  const MatchesScreen({super.key});

  @override
  ConsumerState<MatchesScreen> createState() => _MatchesScreenState();
}

class _MatchesScreenState extends ConsumerState<MatchesScreen> {
  DateTime? date;
  String filter = 'Todos';

  Future<void> _pickDate(BuildContext context, DateTime selected) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: selected,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) setState(() => date = picked);
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
          onTap: () => setState(() => date = candidate),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final requestDate = DateUtils.dateOnly(date ?? costaRicaNow());

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
              : DateUtils.dateOnly(costaRicaNow());
          final selected = DateUtils.dateOnly(date ?? anchor);
          final follows =
              ref.watch(followsProvider).asData?.value ?? <String>{};
          final preference = ref.watch(preferenceProvider).asData?.value;
          final games = data.onDate(selected, filter);

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
            orderMode:
                preference?.competitionOrderMode ??
                CompetitionOrderMode.automatic,
            pinnedCompetitionIds:
                preference?.pinnedCompetitionIds ?? const <String>[],
          );
          final followedCompetitions = orderedCompetitions
              .where(
                (competition) => _isFollowedCompetition(competition, follows),
              )
              .toList();
          final followedCompetitionIds = followedCompetitions
              .map((competition) => competition.id)
              .toSet();
          final allOtherCompetitions = orderedCompetitions
              .where(
                (competition) =>
                    !followedCompetitionIds.contains(competition.id),
              )
              .toList();

          final feedItems = <Widget Function()>[];

          void addCompetition(Entity competition) {
            final competitionMatches =
                remainingByCompetition[competition.id] ??
                const <FootballMatch>[];
            if (competitionMatches.isEmpty) return;

            feedItems.add(
              () => Text(
                competition.country.toUpperCase(),
                style: const TextStyle(
                  color: muted,
                  letterSpacing: 2,
                  fontSize: 11,
                ),
              ),
            );
            feedItems.add(
              () => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  competition.name,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                leading: EntityAvatar(competition, size: 34),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/competition/${competition.id}'),
              ),
            );
            for (final match in competitionMatches) {
              feedItems.add(() => MatchCard(match, data));
            }
            feedItems.add(() => const SizedBox(height: 12));
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
                              color: filter == value
                                  ? const Color(0xFF0B1114)
                                  : Colors.white,
                            ),
                          ),
                          selected: filter == value,
                          onSelected: (_) => setState(() => filter = value),
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
            feedItems.add(
              () => _FeedHeading(
                title: 'TUS EQUIPOS',
                subtitle: data.demo
                    ? 'Solo esos partidos suben; la competición completa no se mueve.'
                    : null,
              ),
            );
            for (final match in followedGames) {
              final competition = data.competition(match.competitionId)!;
              feedItems
                ..add(() => _MatchCompetitionLabel(competition: competition))
                ..add(() => MatchCard(match, data))
                ..add(() => const SizedBox(height: 10));
            }
            feedItems.add(() => const SizedBox(height: 8));
          }

          if (followedCompetitions.isNotEmpty) {
            feedItems.add(
              () => _FeedHeading(
                title: 'TUS COMPETICIONES',
                subtitle: data.demo
                    ? 'Solo las competiciones que elegiste explícitamente.'
                    : null,
              ),
            );
            for (final competition in followedCompetitions) {
              addCompetition(competition);
            }
          }

          if (allOtherCompetitions.isNotEmpty) {
            feedItems.add(
              () => _FeedHeading(
                title: 'TODOS LOS PARTIDOS',
                subtitle: data.demo
                    ? 'Todo lo demás que la fuente entregó para este día, sin ocultar ligas.'
                    : null,
              ),
            );
            for (final competition in allOtherCompetitions) {
              addCompetition(competition);
            }
          }

          // Horizontal fling = previous/next day. Vertical scrolling and
          // inner horizontal lists keep their gestures (gesture arena).
          return GestureDetector(
            key: const ValueKey('matches-date-swipe'),
            behavior: HitTestBehavior.translucent,
            onHorizontalDragEnd: (details) {
              final velocity = details.primaryVelocity ?? 0;
              if (velocity.abs() < _dateSwipeMinVelocity) return;
              setState(
                () => date = DateUtils.dateOnly(
                  selected.add(Duration(days: velocity < 0 ? 1 : -1)),
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
  const _FeedHeading({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6, bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: lime,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.8,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(subtitle!, style: const TextStyle(color: muted, fontSize: 11)),
        ],
      ],
    ),
  );
}

class _MatchCompetitionLabel extends StatelessWidget {
  const _MatchCompetitionLabel({required this.competition});

  final Entity competition;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        EntityAvatar(competition, size: 24),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            competition.name,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
          ),
        ),
        Text(
          competition.country.toUpperCase(),
          style: const TextStyle(color: muted, fontSize: 9, letterSpacing: 1.2),
        ),
      ],
    ),
  );
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
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () =>
            context.push('/match/${match.id}', extra: data.forMatch(match.id)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 18),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: match.statusLabel.isEmpty
                        ? const SizedBox.shrink()
                        : Text(
                            match.statusLabel.toUpperCase(),
                            style: TextStyle(
                              color: match.isLive ? lime : muted,
                              fontSize: 10,
                              letterSpacing: 1,
                            ),
                          ),
                  ),
                  FollowButton('match', match.id),
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
                          home.name,
                          textAlign: TextAlign.center,
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
                          match.showKickoff
                              ? localTime(context, match.startTime)
                              : match.score,
                          style: TextStyle(
                            fontSize: match.showKickoff ? 21 : 30,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          match.showKickoff ? 'Hora Costa Rica' : 'Ver partido',
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
                          away.name,
                          textAlign: TextAlign.center,
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
    );
  }
}

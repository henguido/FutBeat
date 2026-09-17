import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models.dart';
import '../../core/interests.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';
import '../profile/country_preferences.dart';

const _importantCompetitions = <String>{
  'uefa champions league',
  'premier league',
  'la liga',
  'laliga',
  'liga mx',
  'major league soccer',
  'mls',
  'concacaf central american cup',
};

String _normalizedCompetitionName(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll('á', 'a')
    .replaceAll('é', 'e')
    .replaceAll('í', 'i')
    .replaceAll('ó', 'o')
    .replaceAll('ú', 'u');

bool _isImportantCompetition(Entity competition) =>
    _importantCompetitions.contains(_normalizedCompetitionName(competition.name));

bool _isFollowedTeamMatch(FootballMatch match, Set<String> follows) =>
    follows.contains('team:${match.homeId}') ||
    follows.contains('team:${match.awayId}');

bool _isFeaturedCompetition({
  required Entity competition,
  required Set<String> follows,
  required Set<String> temporaryInterests,
  String? selectedCountry,
  String? detectedCountry,
}) =>
    follows.contains('competition:${competition.id}') ||
    temporaryInterests.contains('competition:${competition.id}') ||
    _matchesCountry(competition.country, selectedCountry) ||
    _matchesCountry(competition.country, detectedCountry) ||
    _isImportantCompetition(competition);

String _compactDate(DateTime value) {
  const months = [
    'ENE', 'FEB', 'MAR', 'ABR', 'MAY', 'JUN',
    'JUL', 'AGO', 'SEP', 'OCT', 'NOV', 'DIC',
  ];
  return '${value.day} ${months[value.month - 1]}';
}

List<Entity> orderMatchCompetitions({
  required Snapshot data,
  required List<FootballMatch> matches,
  required Set<String> follows,
  required Set<String> temporaryInterests,
  String? selectedCountry,
  String? detectedCountry,
}) {
  final visible = data.competitions
      .where(
        (competition) =>
            matches.any((match) => match.competitionId == competition.id),
      )
      .toList();

  int priority(Entity competition) {
    if (follows.contains('competition:${competition.id}')) return 0;
    if (_matchesCountry(competition.country, selectedCountry)) return 1;
    if (_matchesCountry(competition.country, detectedCountry)) return 2;
    if (_isImportantCompetition(competition)) return 3;
    if (temporaryInterests.contains('competition:${competition.id}')) return 4;
    return 5;
  }

  return visible..sort((left, right) {
    final byPriority = priority(left).compareTo(priority(right));
    if (byPriority != 0) return byPriority;
    final byName = left.name.toLowerCase().compareTo(right.name.toLowerCase());
    return byName != 0 ? byName : left.id.compareTo(right.id);
  });
}

bool _matchesCountry(String country, String? code) {
  if (code == null) return false;
  final value = country
      .trim()
      .toLowerCase()
      .replaceAll('é', 'e')
      .replaceAll('ñ', 'n');
  final aliases = switch (code.toUpperCase()) {
    'CR' => const {'costa rica'},
    'MX' => const {'mexico'},
    'AR' => const {'argentina'},
    'BR' => const {'brasil', 'brazil'},
    'ES' => const {'espana', 'spain'},
    'US' => const {'estados unidos', 'united states', 'usa'},
    'GB' => const {
      'reino unido',
      'united kingdom',
      'england',
      'scotland',
      'wales',
      'northern ireland',
    },
    _ => {code.toLowerCase()},
  };
  return aliases.contains(value);
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

  @override
  Widget build(BuildContext context) => Scaffold(
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
    body: DataView(
      builder: (data) {
        final anchor = data.demo
            ? DateTime(2026, 9, 15)
            : DateUtils.dateOnly(costaRicaNow());
        final selected = date ?? anchor;
        final preference = ref.watch(preferenceProvider).asData?.value;
        final follows = ref.watch(followsProvider).asData?.value ?? <String>{};
        final temporaryInterests =
            ref.watch(temporaryInterestsProvider).asData?.value ?? <String>{};
        final games = data.onDate(selected, filter);

        final followedGames = games
            .where((match) => _isFollowedTeamMatch(match, follows))
            .toList()
          ..sort((a, b) => a.startTime.compareTo(b.startTime));
        final followedIds = followedGames.map((match) => match.id).toSet();
        final remainingGames = games
            .where((match) => !followedIds.contains(match.id))
            .toList();
        final orderedCompetitions = orderMatchCompetitions(
          data: data,
          matches: remainingGames,
          follows: follows,
          temporaryInterests: temporaryInterests,
          selectedCountry: preference?.selectedCountry,
          detectedCountry: preference?.detectedCountry,
        );
        final featuredCompetitions = orderedCompetitions
            .where(
              (competition) => _isFeaturedCompetition(
                competition: competition,
                follows: follows,
                temporaryInterests: temporaryInterests,
                selectedCountry: preference?.selectedCountry,
                detectedCountry: preference?.detectedCountry,
              ),
            )
            .toList();
        final featuredIds = featuredCompetitions
            .map((competition) => competition.id)
            .toSet();
        final otherCompetitions = orderedCompetitions
            .where((competition) => !featuredIds.contains(competition.id))
            .toList();

        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(snapshotProvider);
            try {
              await ref.read(snapshotProvider.future);
            } catch (_) {
              // DataView exposes the provider error and retry action.
            }
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              const Text(
                'EL LATIDO DEL FÚTBOL',
                style: TextStyle(color: muted, fontSize: 10, letterSpacing: 3),
              ),
              const SizedBox(height: 20),
              if (data.demo) const DemoNotice(),
              if (!data.demo) CountryPreferencePanel(compact: true, data: data),
              if (!data.demo) const SizedBox(height: 16),
              Row(
                children: [
                  for (final (offset, label) in [
                    (-1, 'AYER'),
                    (0, 'HOY'),
                    (1, 'MAÑANA'),
                  ])
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: _DateOption(
                          label: label,
                          date: DateTime(
                            anchor.year,
                            anchor.month,
                            anchor.day + offset,
                          ),
                          selected: DateUtils.isSameDay(
                            selected,
                            DateTime(
                              anchor.year,
                              anchor.month,
                              anchor.day + offset,
                            ),
                          ),
                          onTap: () => setState(
                            () => date = DateTime(
                              anchor.year,
                              anchor.month,
                              anchor.day + offset,
                            ),
                          ),
                        ),
                      ),
                    ),
                  SizedBox(
                    width: 46,
                    height: 52,
                    child: IconButton.filledTonal(
                      tooltip: 'Elegir otra fecha',
                      onPressed: () => _pickDate(context, selected),
                      icon: const Icon(Icons.calendar_month_outlined),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SingleChildScrollView(
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
              const SizedBox(height: 16),
              if (games.isEmpty)
                EmptyState(
                  'Sin partidos para esta selección',
                  data.coverage?['partial'] == true
                      ? 'La fuente puede no incluir todos los partidos. Consulta las fechas disponibles.'
                      : 'Prueba otra fecha o cambia el filtro.',
                ),
              if (games.isEmpty && !data.demo && data.matches.isNotEmpty)
                Wrap(
                  spacing: 8,
                  children: [
                    for (final available
                        in (data.matches
                            .map((m) => DateUtils.dateOnly(m.startTime))
                            .toSet()
                            .toList()
                          ..sort()))
                      ActionChip(
                        label: Text(
                          '${available.day}/${available.month}/${available.year}',
                        ),
                        onPressed: () => setState(() {
                          date = available;
                          filter = 'Todos';
                        }),
                      ),
                  ],
                ),
              if (followedGames.isNotEmpty) ...[
                const _FeedHeading(
                  title: 'EQUIPOS QUE SIGUES',
                  subtitle: 'Sus partidos aparecen primero, sin mover toda la competición.',
                ),
                for (final match in followedGames) ...[
                  _MatchCompetitionLabel(
                    competition: data.competition(match.competitionId)!,
                  ),
                  MatchCard(match, data),
                  const SizedBox(height: 10),
                ],
                const SizedBox(height: 8),
              ],
              if (featuredCompetitions.isNotEmpty) ...[
                const _FeedHeading(
                  title: 'COMPETICIONES DESTACADAS',
                  subtitle: 'Tus ligas, tu país y las competiciones principales.',
                ),
                for (final competition in featuredCompetitions)
                  _CompetitionBlock(
                    competition: competition,
                    matches: remainingGames
                        .where((m) => m.competitionId == competition.id)
                        .toList(),
                    data: data,
                  ),
              ],
              if (otherCompetitions.isNotEmpty) ...[
                const _FeedHeading(
                  title: 'TODOS LOS PARTIDOS',
                  subtitle: 'El resto de encuentros disponibles para este día.',
                ),
                for (final competition in otherCompetitions)
                  _CompetitionBlock(
                    competition: competition,
                    matches: remainingGames
                        .where((m) => m.competitionId == competition.id)
                        .toList(),
                    data: data,
                  ),
              ],
            ],
          ),
        );
      },
    ),
  );
}

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
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: selected ? null : Border.all(color: const Color(0xFF394246)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: TextStyle(
                color: selected ? const Color(0xFF0B1114) : muted,
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              _compactDate(date),
              style: TextStyle(
                color: selected ? const Color(0xFF0B1114) : Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _FeedHeading extends StatelessWidget {
  const _FeedHeading({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

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
        const SizedBox(height: 4),
        Text(subtitle, style: const TextStyle(color: muted, fontSize: 11)),
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

class _CompetitionBlock extends StatelessWidget {
  const _CompetitionBlock({
    required this.competition,
    required this.matches,
    required this.data,
  });

  final Entity competition;
  final List<FootballMatch> matches;
  final Snapshot data;

  @override
  Widget build(BuildContext context) {
    if (matches.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          competition.country.toUpperCase(),
          style: const TextStyle(
            color: muted,
            letterSpacing: 2,
            fontSize: 11,
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            competition.name,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          leading: EntityAvatar(competition, size: 34),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/competition/${competition.id}'),
        ),
        for (final match in matches) MatchCard(match, data),
        const SizedBox(height: 12),
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
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => context.push('/match/${match.id}'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 18),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
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
                          match.isUpcoming
                              ? localTime(context, match.startTime)
                              : match.score,
                          style: TextStyle(
                            fontSize: match.isUpcoming ? 21 : 30,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          match.isUpcoming ? 'Hora Costa Rica' : 'Ver partido',
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
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';

class MatchesScreen extends ConsumerStatefulWidget {
  const MatchesScreen({super.key});
  @override
  ConsumerState<MatchesScreen> createState() => _MatchesScreenState();
}

class _MatchesScreenState extends ConsumerState<MatchesScreen> {
  DateTime? date;
  String filter = 'Todos';
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
            : DateUtils.dateOnly(DateTime.now());
        final selected = date ?? anchor;
        final games = data.onDate(selected, filter);
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
              Row(
                children: [
                  IconButton(
                    tooltip: 'Día anterior',
                    onPressed: () => setState(
                      () => date = DateTime(
                        selected.year,
                        selected.month,
                        selected.day - 1,
                      ),
                    ),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: TextButton(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: selected,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) setState(() => date = picked);
                      },
                      child: Text(
                        '${selected.day}/${selected.month}/${selected.year}',
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Día siguiente',
                    onPressed: () => setState(
                      () => date = DateTime(
                        selected.year,
                        selected.month,
                        selected.day + 1,
                      ),
                    ),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              Row(
                children: [
                  for (final (offset, label) in [
                    (-1, 'Ayer'),
                    (0, 'Hoy'),
                    (1, 'Mañana'),
                  ])
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: ChoiceChip(
                          label: Text(
                            label,
                            style: TextStyle(
                              color:
                                  DateUtils.isSameDay(
                                    selected,
                                    DateTime(
                                      anchor.year,
                                      anchor.month,
                                      anchor.day + offset,
                                    ),
                                  )
                                  ? const Color(0xFF0B1114)
                                  : Colors.white,
                            ),
                          ),
                          selected: DateUtils.isSameDay(
                            selected,
                            DateTime(
                              anchor.year,
                              anchor.month,
                              anchor.day + offset,
                            ),
                          ),
                          onSelected: (_) => setState(
                            () => date = DateTime(
                              anchor.year,
                              anchor.month,
                              anchor.day + offset,
                            ),
                          ),
                        ),
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
                const EmptyState(
                  'Sin partidos para esta selección',
                  'Prueba otra fecha o cambia el filtro.',
                ),
              for (final competition in data.competitions.where(
                (c) => games.any((m) => m.competitionId == c.id),
              )) ...[
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
                  leading: const Icon(Icons.emoji_events_outlined, color: lime),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/competition/${competition.id}'),
                ),
                for (final match in games.where(
                  (m) => m.competitionId == competition.id,
                ))
                  MatchCard(match, data),
                const SizedBox(height: 12),
              ],
            ],
          ),
        );
      },
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
                          match.isUpcoming ? 'Hora local' : 'Ver partido',
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

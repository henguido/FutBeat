import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/interests.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';
import '../entities/standings.dart';

class MatchScreen extends ConsumerStatefulWidget {
  const MatchScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<MatchScreen> createState() => _MatchScreenState();
}

class _MatchScreenState extends ConsumerState<MatchScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => recordTemporaryInterest(ref, 'match', widget.id));
  }

  @override
  Widget build(BuildContext context) => DataView(
    builder: (data) {
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
      final competition = data.competition(match.competitionId)!;
      return DefaultTabController(
        length: 4,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Match Center'),
            actions: [FollowButton('match', widget.id)],
            bottom: const TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(text: 'Resumen'),
                Tab(text: 'Estadísticas'),
                Tab(text: 'Alineaciones'),
                Tab(text: 'Tabla'),
              ],
            ),
          ),
          body: TabBarView(
            children: [
              ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  if (data.demo) const DemoNotice(),
                  Center(
                    child: TextButton(
                      onPressed: () =>
                          context.push('/competition/${competition.id}'),
                      child: Text(competition.name),
                    ),
                  ),
                  Row(
                    children: [
                      for (final teamId in [match.homeId, match.awayId])
                        Expanded(
                          child: InkWell(
                            onTap: () => context.push('/team/$teamId'),
                            child: Column(
                              children: [
                                EntityAvatar(data.team(teamId)!, size: 64),
                                const SizedBox(height: 12),
                                Text(
                                  data.team(teamId)!.name,
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Center(
                    child: Text(
                      match.score,
                      style: const TextStyle(
                        fontSize: 44,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Center(
                    child: Text(
                      match.statusLabel,
                      style: const TextStyle(color: lime),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: Text(
                      '${match.startTime.day}/${match.startTime.month} · ${localTime(context, match.startTime)} · Hora local',
                      style: const TextStyle(color: muted),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      match.json['venue'] as String,
                      style: const TextStyle(color: muted, fontSize: 12),
                    ),
                  ),
                  heading(context, 'Eventos del partido'),
                  if (match.events.isEmpty)
                    const EmptyState(
                      'Sin eventos disponibles',
                      'Los eventos aparecerán cuando la fuente los publique.',
                    ),
                  if (match.events.isNotEmpty)
                    Card(
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          for (var index = 0; index < match.events.length; index++) ...[
                            Builder(
                              builder: (context) {
                                final event = match.events[index];
                                final type = event['type'] as String? ?? '';
                                final team = data.team(
                                  event['teamId'] as String? ?? '',
                                );
                                final player = data.player(
                                  event['playerId'] as String? ?? '',
                                );
                                final detail = event['detail']?.toString().trim();
                                return ListTile(
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 3,
                                  ),
                                  leading: SizedBox(
                                    width: 42,
                                    child: Text(
                                      "${event['minute'] ?? '—'}′",
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: lime,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                  title: Text(
                                    player?.name ?? eventLabel(type),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  subtitle: Text(
                                    [
                                      eventLabel(type),
                                      if (team != null) team.name,
                                      if (detail != null && detail.isNotEmpty)
                                        detail,
                                    ].join(' · '),
                                  ),
                                  trailing: EventBadge(type),
                                  onTap: player == null
                                      ? null
                                      : () => context.push(
                                          '/player/${event['playerId']}',
                                        ),
                                );
                              },
                            ),
                            if (index < match.events.length - 1)
                              const Divider(height: 1, indent: 70),
                          ],
                        ],
                      ),
                    ),
                  heading(context, 'Estadísticas clave'),
                  Statistics(match),
                  const SizedBox(height: 20),
                  Text(
                    'Fuente: ${match.json['liveProvider'] ?? match.json['provenance']['source']}',
                    style: const TextStyle(fontSize: 11, color: muted),
                  ),
                  Text(
                    'Actualización: ${DateTime.parse((match.json['liveChangedAt'] ?? match.json['provenance']['receivedAt']) as String).toLocal()}',
                    style: const TextStyle(fontSize: 11, color: muted),
                  ),
                ],
              ),
              ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  if (data.demo) const DemoNotice(),
                  Text(
                    '${data.team(match.homeId)!.name} / ${data.team(match.awayId)!.name}',
                  ),
                  const SizedBox(height: 20),
                  Statistics(match),
                ],
              ),
              const SingleChildScrollView(
                child: EmptyState(
                  'Alineaciones no disponibles',
                  'No hay una alineación publicada para este encuentro.',
                ),
              ),
              ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  if (data.demo) const DemoNotice(),
                  Standings(data, match.competitionId),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

class Statistics extends StatelessWidget {
  const Statistics(this.match, {super.key});
  final FootballMatch match;
  @override
  Widget build(BuildContext context) => match.statistics.isEmpty
      ? const EmptyState(
          'Sin estadísticas disponibles',
          'Mostraremos únicamente los datos publicados por la fuente.',
        )
      : Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                for (final stat in match.statistics)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      children: [
                        Text(
                          '${stat['home']}${stat['unit']}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Expanded(
                          child: Text(
                            stat['label'] as String,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: muted),
                          ),
                        ),
                        Text(
                          '${stat['away']}${stat['unit']}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
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
  'VAR' => 'VAR',
  'MISSED_PENALTY' => 'Penal fallado',
  'KICKOFF' => 'Inicio',
  'HALFTIME' => 'Medio tiempo',
  'FULL_TIME' => 'Final',
  _ => 'Evento',
};

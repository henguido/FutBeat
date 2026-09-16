import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';
import '../entities/standings.dart';

class MatchScreen extends StatelessWidget {
  const MatchScreen({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext context) => DataView(
    builder: (data) {
      final match = data.match(id);
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
            actions: [FollowButton('match', id)],
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
                  Card(
                    child: Column(
                      children: [
                        for (final event in match.events)
                          ListTile(
                            leading: Text(
                              "${event['minute'] ?? '—'}′",
                              style: const TextStyle(color: lime),
                            ),
                            title: Text(
                              data
                                      .player(
                                        event['playerId'] as String? ?? '',
                                      )
                                      ?.name ??
                                  eventLabel(event['type'] as String? ?? ''),
                            ),
                            subtitle: Text(
                              [
                                eventLabel(event['type'] as String? ?? ''),
                                if (data.team(
                                      event['teamId'] as String? ?? '',
                                    ) !=
                                    null)
                                  data.team(event['teamId'] as String)!.name,
                              ].join(' · '),
                            ),
                            trailing: Icon(
                              event['type'] == 'GOAL'
                                  ? Icons.sports_soccer
                                  : Icons.square,
                              size: 20,
                              color: event['type'] == 'GOAL'
                                  ? Colors.white
                                  : event['type'] == 'RED_CARD'
                                  ? Colors.red
                                  : Colors.amber,
                            ),
                            onTap:
                                data.player(
                                      event['playerId'] as String? ?? '',
                                    ) ==
                                    null
                                ? null
                                : () => context.push(
                                    '/player/${event['playerId']}',
                                  ),
                          ),
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

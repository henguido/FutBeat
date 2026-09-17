import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/interests.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';
import '../matches/matches_screen.dart';
import 'standings.dart';

class EntityScreen extends ConsumerStatefulWidget {
  const EntityScreen({super.key, required this.type, required this.id});
  final String type, id;
  @override
  ConsumerState<EntityScreen> createState() => _EntityScreenState();
}

class _EntityScreenState extends ConsumerState<EntityScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => recordTemporaryInterest(ref, widget.type, widget.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.type, id = widget.id;
    return DataView(
      builder: (data) {
        final entity = switch (type) {
          'team' => data.team(id),
          'player' => data.player(id),
          _ => data.competition(id),
        };
        if (entity == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('FutBeat')),
            body: const EmptyState(
              'Perfil no encontrado',
              'Busca otra entidad desde Explorar.',
            ),
          );
        }
        final teamId = type == 'player' ? entity.json['teamId'] as String : id;
        final competitionId = type == 'competition'
            ? id
            : type == 'player'
            ? data.team(teamId)!.json['competitionId'] as String
            : entity.json['competitionId'] as String;
        final matches =
            data.matches
                .where(
                  (m) => type == 'competition'
                      ? m.competitionId == id
                      : m.homeId == teamId || m.awayId == teamId,
                )
                .toList()
              ..sort((a, b) => a.startTime.compareTo(b.startTime));
        final tabs = type == 'player'
            ? ['Resumen', 'Partidos', 'Noticias', 'Transferencias']
            : [
                'Resumen',
                'Partidos',
                'Tabla',
                type == 'team' ? 'Plantilla' : 'Equipos',
                'Noticias',
                'Transferencias',
              ];
        return DefaultTabController(
          length: tabs.length,
          child: Scaffold(
            appBar: AppBar(
              title: Text(entity.name),
              actions: [FollowButton(type, id)],
              bottom: TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: tabs.map((t) => Tab(text: t)).toList(),
              ),
            ),
            body: TabBarView(
              children: [
                for (final tab in tabs)
                  ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      if (data.demo) const DemoNotice(),
                      if (tab == 'Resumen') ...[
                        Center(child: EntityAvatar(entity, size: 80)),
                        const SizedBox(height: 16),
                        Center(
                          child: Text(
                            entity.name,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Center(
                          child: Text(
                            entity.country,
                            style: const TextStyle(color: muted),
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (type == 'player') ...[
                          Center(
                            child: Text(entity.json['position'] as String),
                          ),
                          heading(context, 'Equipo actual'),
                          EntityTile(data.team(teamId)!, 'team'),
                        ] else if (type == 'team')
                          EntityTile(
                            data.competition(competitionId)!,
                            'competition',
                          )
                        else
                          Center(
                            child: Text(
                              entity.json['season'] as String,
                              style: const TextStyle(color: muted),
                            ),
                          ),
                        heading(context, 'Partidos destacados'),
                        if (matches.isEmpty)
                          const EmptyState(
                            'Sin partidos disponibles',
                            'El calendario se mostrará cuando esté disponible.',
                          ),
                        for (final match
                            in matches
                                .where((m) => m.isLive || m.isUpcoming)
                                .take(2))
                          MatchCard(match, data),
                        if (matches.any((m) => m.isFinished)) ...[
                          heading(context, 'Último resultado'),
                          MatchCard(
                            matches.where((m) => m.isFinished).last,
                            data,
                          ),
                        ],
                      ] else if (tab == 'Partidos') ...[
                        if (matches.isEmpty)
                          const EmptyState(
                            'Sin partidos disponibles',
                            'No hay encuentros asociados a este perfil.',
                          ),
                        for (final match in matches) ...[
                          Text(
                            '${match.startTime.day}/${match.startTime.month}/${match.startTime.year}',
                            style: const TextStyle(color: muted),
                          ),
                          const SizedBox(height: 8),
                          MatchCard(match, data),
                        ],
                      ] else if (tab == 'Tabla')
                        Standings(data, competitionId)
                      else if (tab == 'Plantilla') ...[
                        Text(
                          data.demo
                              ? 'Selección de jugadores de demostración'
                              : 'Jugadores disponibles',
                          style: const TextStyle(color: muted),
                        ),
                        const SizedBox(height: 12),
                        if (!data.players.any((p) => p.json['teamId'] == id))
                          const EmptyState(
                            'Plantilla no disponible',
                            'No hay jugadores publicados para este equipo.',
                          ),
                        for (final player in data.players.where(
                          (p) => p.json['teamId'] == id,
                        ))
                          EntityTile(player, 'player'),
                      ] else if (tab == 'Equipos') ...[
                        for (final team in data.teams.where(
                          (t) => t.json['competitionId'] == id,
                        ))
                          EntityTile(team, 'team'),
                      ] else if (tab == 'Noticias')
                        const EmptyState(
                          'Sin noticias disponibles',
                          'Aquí encontrarás contenido relacionado con este perfil.',
                          icon: Icons.article_outlined,
                        )
                      else
                        const EmptyState(
                          'Sin transferencias disponibles',
                          'Los movimientos incluirán su fuente y se distinguirán los rumores de las confirmaciones.',
                          icon: Icons.swap_horiz,
                        ),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

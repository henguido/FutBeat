import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/interests.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';
import '../matches/matches_screen.dart';
import 'standings.dart';
import 'team_profile.dart';

List<Entity> orderedTeamCompetitions(Snapshot data, String teamId) {
  final counts = <String, int>{};
  final activeCounts = <String, int>{};

  for (final match in data.matches.where(
    (match) => match.homeId == teamId || match.awayId == teamId,
  )) {
    counts.update(match.competitionId, (value) => value + 1, ifAbsent: () => 1);
    if (match.isLive || match.isUpcoming) {
      activeCounts.update(
        match.competitionId,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
    }
  }

  final fallback = data.team(teamId)?.json['competitionId']?.toString();
  final ids = <String>{...counts.keys};
  if (fallback != null && fallback.isNotEmpty) ids.add(fallback);

  final competitions = ids.map(data.competition).whereType<Entity>().toList();
  competitions.sort((left, right) {
    final byMatches = (counts[right.id] ?? 0).compareTo(counts[left.id] ?? 0);
    if (byMatches != 0) return byMatches;
    final byActive = (activeCounts[right.id] ?? 0).compareTo(
      activeCounts[left.id] ?? 0,
    );
    if (byActive != 0) return byActive;
    return left.name.toLowerCase().compareTo(right.name.toLowerCase());
  });
  return competitions;
}

List<Entity> competitionTeams(Snapshot data, String competitionId) {
  final ids = <String>{};

  for (final match in data.matches.where(
    (match) => match.competitionId == competitionId,
  )) {
    ids
      ..add(match.homeId)
      ..add(match.awayId);
  }

  for (final table in data.standings.where(
    (table) => table['competitionId'] == competitionId,
  )) {
    for (final row in (table['rows'] as List? ?? []).whereType<Map>()) {
      final teamId = row['teamId']?.toString();
      if (teamId != null && teamId.isNotEmpty) ids.add(teamId);
    }
  }

  for (final team in data.teams.where(
    (team) => team.json['competitionId']?.toString() == competitionId,
  )) {
    ids.add(team.id);
  }

  final teams = ids.map(data.team).whereType<Entity>().toList()
    ..sort(
      (left, right) =>
          left.name.toLowerCase().compareTo(right.name.toLowerCase()),
    );
  return teams;
}

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
    final detail = ref.watch(entitySnapshotProvider((type: type, id: id)));

    return detail.when(
      loading: () => Scaffold(
        appBar: AppBar(title: const Text('FutBeat')),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (_, stack) => Scaffold(
        appBar: AppBar(title: const Text('FutBeat')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const EmptyState(
                'No pudimos cargar este perfil',
                'Revisa tu conexión e intenta nuevamente.',
                icon: Icons.cloud_off,
              ),
              FilledButton(
                onPressed: () => ref.invalidate(
                  entitySnapshotProvider((type: type, id: id)),
                ),
                child: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      ),
      data: (data) {
        final canonicalId = data.resolveEntityId(id);
        final entity = switch (type) {
          'team' => data.team(canonicalId),
          'player' => data.player(canonicalId),
          _ => data.competition(canonicalId),
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
        final teamId = switch (type) {
          'player' => entity.json['teamId']?.toString(),
          'team' => canonicalId,
          _ => null,
        };
        final team = teamId == null ? null : data.team(teamId);
        final matches =
            data.matches
                .where(
                  (m) => type == 'competition'
                      ? m.competitionId == canonicalId
                      : teamId != null &&
                            (m.homeId == teamId || m.awayId == teamId),
                )
                .toList()
              ..sort((a, b) => a.startTime.compareTo(b.startTime));
        final teamCompetitions = teamId == null
            ? const <Entity>[]
            : orderedTeamCompetitions(data, teamId);
        if (type == 'team') {
          return TeamProfileView(
            data: data,
            team: entity,
            competitions: teamCompetitions,
            matches: matches,
          );
        }
        final competitionId = type == 'competition'
            ? canonicalId
            : type == 'team'
            ? teamCompetitions.firstOrNull?.id
            : null;
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
              actions: [FollowButton(type, canonicalId)],
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
                          PlayerProfileFacts(entity),
                          heading(context, 'Equipo actual'),
                          if (team != null)
                            EntityTile(team, 'team')
                          else
                            const EmptyState(
                              'Equipo no disponible',
                              'El equipo actual todavía no está publicado.',
                            ),
                        ] else if (type == 'team') ...[
                          heading(context, 'Competiciones'),
                          if (teamCompetitions.isEmpty)
                            const EmptyState(
                              'Competiciones no disponibles',
                              'Las competiciones aparecerán según los partidos publicados.',
                            ),
                          for (final competition in teamCompetitions.take(3))
                            EntityTile(competition, 'competition'),
                        ] else ...[
                          if ((entity.json['season']?.toString() ?? '')
                              .isNotEmpty)
                            Center(
                              child: Text(
                                entity.json['season'].toString(),
                                style: const TextStyle(color: muted),
                              ),
                            ),
                        ],
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
                        if (competitionId != null)
                          Standings(data, competitionId)
                        else
                          const EmptyState(
                            'Tabla no disponible',
                            'No hay competición asociada a este perfil.',
                          )
                      else if (tab == 'Plantilla') ...[
                        Text(
                          data.demo
                              ? 'Selección de jugadores de demostración'
                              : 'Jugadores disponibles',
                          style: const TextStyle(color: muted),
                        ),
                        const SizedBox(height: 12),
                        if (!data.players.any(
                          (p) => p.json['teamId'] == canonicalId,
                        ))
                          const EmptyState(
                            'Plantilla no disponible',
                            'No hay jugadores publicados para este equipo.',
                          ),
                        for (final player in data.players.where(
                          (p) => p.json['teamId'] == canonicalId,
                        ))
                          EntityTile(player, 'player'),
                      ] else if (tab == 'Equipos') ...[
                        for (final team in competitionTeams(data, canonicalId))
                          EntityTile(team, 'team'),
                      ] else if (tab == 'Noticias') ...[
                        if (data.news.isEmpty)
                          const EmptyState(
                            'Sin noticias disponibles',
                            'Aquí encontrarás contenido relacionado con este perfil.',
                            icon: Icons.article_outlined,
                          ),
                        for (final article in data.news)
                          NewsArticleCard(article),
                      ] else ...[
                        if (data.transfers.isEmpty)
                          const EmptyState(
                            'Sin cambios de plantilla disponibles',
                            'Los movimientos aparecerán cuando una fuente de plantilla confirme un cambio de club.',
                            icon: Icons.swap_horiz,
                          ),
                        for (final transfer in data.transfers)
                          TransferEventCard(transfer),
                      ],
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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/interests.dart';
import '../../core/models.dart';
import '../../core/profile_context.dart';
import '../../core/providers.dart';
import '../../core/relevance.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';
import '../matches/matches_screen.dart';
import 'player_profile.dart';
import 'standings.dart';
import 'team_profile.dart';
import 'team_summary.dart' show NextMatchCard, nextTeamMatch;

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
    return left.displayName.toLowerCase().compareTo(
      right.displayName.toLowerCase(),
    );
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
      (left, right) => left.displayName.toLowerCase().compareTo(
        right.displayName.toLowerCase(),
      ),
    );
  return teams;
}

class EntityScreen extends ConsumerStatefulWidget {
  const EntityScreen({
    super.key,
    required this.type,
    required this.id,
    this.competitionId,
    this.season,
  });
  final String type, id;

  /// Initial profile context (opened from a match), when given.
  final String? competitionId, season;
  @override
  ConsumerState<EntityScreen> createState() => _EntityScreenState();
}

/// Bounded refreshes while the server hydrates a profile on demand.
const profileEnrichmentRetryDelays = [
  Duration(seconds: 6),
  Duration(seconds: 12),
];

class _EntityScreenState extends ConsumerState<EntityScreen> {
  Timer? enrichmentRetry;
  int enrichmentAttempts = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => recordTemporaryInterest(ref, widget.type, widget.id),
    );
    // Fresh profile context on every open (#161): only this request, only
    // when an answer (or a failure) is already cached; one read per open.
    if (widget.type == 'team') {
      final choice = ref.read(profileContextSelectionProvider)[widget.id];
      final request = (
        teamId: widget.id,
        competitionId: choice?.competitionId ?? widget.competitionId,
        season: choice != null ? choice.season : widget.season,
      );
      if (ref.exists(teamContextProvider(request))) {
        ref.invalidate(teamContextProvider(request));
      }
    }
  }

  @override
  void dispose() {
    enrichmentRetry?.cancel();
    super.dispose();
  }

  void _scheduleEnrichmentRefresh() {
    if (enrichmentRetry != null ||
        enrichmentAttempts >= profileEnrichmentRetryDelays.length) {
      return;
    }
    enrichmentRetry = Timer(
      profileEnrichmentRetryDelays[enrichmentAttempts],
      () {
        if (!mounted) return;
        setState(() {
          enrichmentAttempts++;
          enrichmentRetry = null;
        });
        ref.invalidate(
          entitySnapshotProvider((type: widget.type, id: widget.id)),
        );
      },
    );
  }

  /// Opening a team asks the server for its squad, which also brings its
  /// crest: while either is still missing, the same bounded refreshes pick
  /// them up (the team endpoint never says enrichmentPending).
  bool _teamHydrating(Snapshot data, String id) {
    if (widget.type != 'team') return false;
    final team = data.team(data.resolveEntityId(id));
    return team != null &&
        (data.squadState == 'PENDING' || team.imageUrl == null);
  }

  TeamProfileView _teamView(
    Snapshot data,
    Entity team,
    List<FootballMatch> matches,
    List<Entity> competitions, {
    bool loading = false,
  }) => TeamProfileView(
    data: data,
    team: team,
    competitions: competitions,
    matches: matches,
    initialCompetitionId: widget.competitionId,
    initialSeason: widget.season,
    loading: loading,
  );

  /// Looked up once per screen: the seed only changes with new reads.
  Snapshot? _seed;
  bool _seedLooked = false;

  /// The team profile painted from what this session already read about the
  /// team (see [ApiRepository.entitySeed]) while `/v1/entity` loads; null
  /// when nothing is known (then the screen keeps its spinner).
  Widget? _seededTeamView() {
    if (widget.type != 'team') return null;
    if (!_seedLooked) {
      _seedLooked = true;
      final repository = ref.read(repositoryProvider);
      if (repository is ApiRepository) {
        _seed = repository.entitySeed(widget.type, widget.id);
      }
    }
    final seed = _seed;
    if (seed == null) return null;
    final canonicalId = seed.resolveEntityId(widget.id);
    final team = seed.team(canonicalId);
    if (team == null) return null;
    return _teamView(
      seed,
      team,
      const [],
      orderedTeamCompetitions(seed, canonicalId),
      loading: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.type, id = widget.id;
    ref.listen(entitySnapshotProvider((type: type, id: id)), (_, next) {
      // Ignore the refresh-in-progress state (it still carries old data).
      final value = next.isLoading ? null : next.asData?.value;
      if (value != null &&
          (value.enrichmentPending || _teamHydrating(value, id))) {
        _scheduleEnrichmentRefresh();
      }
    });
    final detail = ref.watch(entitySnapshotProvider((type: type, id: id)));

    return detail.when(
      // First open: paint what the session already knows (header, context,
      // matches tab) while the profile loads; a full-screen spinner only when
      // nothing is known about the entity yet.
      loading: () =>
          _seededTeamView() ??
          Scaffold(
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
          return _teamView(data, entity, matches, teamCompetitions);
        }
        if (type == 'player') {
          return PlayerProfileView(
            data: data,
            player: entity,
            team: team,
            matches: matches,
            enriching:
                data.enrichmentPending &&
                enrichmentAttempts < profileEnrichmentRetryDelays.length,
          );
        }
        // Teams and players have dedicated profiles; this is the competition
        // profile.
        final competitionId = canonicalId;
        const tabs = [
          'Resumen',
          'Partidos',
          'Tabla',
          'Equipos',
          'Noticias',
          'Transferencias',
        ];
        return DefaultTabController(
          length: tabs.length,
          child: Scaffold(
            appBar: AppBar(
              title: Text(entity.displayName),
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
                            entity.displayName,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Center(
                          child: Text(
                            entityCountryLabel(entity) ?? '',
                            style: const TextStyle(color: muted),
                          ),
                        ),
                        const SizedBox(height: 8),
                        if ((entity.json['season']?.toString() ?? '')
                            .isNotEmpty)
                          Center(
                            child: Text(
                              entity.json['season'].toString(),
                              style: const TextStyle(color: muted),
                            ),
                          ),
                        // The real next match (live now, else the soonest
                        // upcoming; never a past one), only when there is one.
                        if (nextTeamMatch(matches, data) case final next?) ...[
                          heading(
                            context,
                            next.isLive ? 'En vivo' : 'Partido siguiente',
                          ),
                          NextMatchCard(match: next, data: data, teamId: ''),
                        ],
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
                      else if (tab == 'Equipos') ...[
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

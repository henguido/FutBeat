import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/interests.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
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
      final detail =
          ref.watch(matchDetailProvider(widget.id)).asData?.value ??
          MatchDetail.empty(widget.id);
      final venue =
          detail.stadium ?? match.json['venue']?.toString() ?? '';
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
                  Center(child: _MatchStatePill(match)),

                  const SizedBox(height: 12),
                  Center(
                    child: Text(
                      '${match.startTime.day}/${match.startTime.month} · ${localTime(context, match.startTime)} · Hora local',
                      style: const TextStyle(color: muted),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (venue.trim().isNotEmpty)
                    Center(
                      child: Text(
                        venue,
                        style: const TextStyle(color: muted, fontSize: 12),
                      ),
                    ),
                  if (detail.referee != null || detail.round != null) ...[
                    const SizedBox(height: 8),
                    Center(
                      child: Text(
                        [
                          if (detail.round != null) 'Jornada ${detail.round}',
                          if (detail.referee != null) 'Árbitro: ${detail.referee}',
                        ].join(' · '),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: muted, fontSize: 12),
                      ),
                    ),
                  ],
                  if (detail.pending) ...[
                    const SizedBox(height: 16),
                    _DetailPendingCard(
                      onRefresh: () =>
                          ref.invalidate(matchDetailProvider(widget.id)),
                    ),
                  ],
                  heading(context, 'Eventos del partido'),
                  if (match.events.isEmpty && detail.incidents.isEmpty)
                    const EmptyState(
                      'Sin eventos disponibles',
                      'Los eventos aparecerán cuando la fuente los publique.',
                    ),
                  if (match.events.isEmpty && detail.incidents.isNotEmpty)
                    DetailIncidents(detail),
                  if (match.events.isNotEmpty)
                    Card(
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          for (final event in match.events)
                            Builder(
                              builder: (context) {
                                final type = event['type'] as String? ?? '';
                                final team = data.team(
                                  event['teamId'] as String? ?? '',
                                );
                                final player = data.player(
                                  event['playerId'] as String? ?? '',
                                );
                                final detail = event['detail']?.toString();
                                return ListTile(
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 3,
                                  ),
                                  leading: SizedBox(
                                    width: 42,
                                    child: Text(
                                      eventMinuteLabel(event),
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
                                      if (detail?.isNotEmpty == true) detail!,
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
                        ],
                      ),
                    ),
                  heading(context, 'Estadísticas clave'),
                  Statistics(match, detail: detail),
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
                  Statistics(match, detail: detail),
                ],
              ),
              ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  if (data.demo) const DemoNotice(),
                  Lineups(data, match, detail),
                ],
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

class _MatchStatePill extends StatelessWidget {
  const _MatchStatePill(this.match);

  final FootballMatch match;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    decoration: BoxDecoration(
      color: (match.isLive ? lime : muted).withValues(alpha: .12),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(
        color: (match.isLive ? lime : muted).withValues(alpha: .35),
      ),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (match.isLive) ...[
          const Icon(Icons.circle, size: 8, color: lime),
          const SizedBox(width: 7),
        ],
        Text(
          match.statusLabel.toUpperCase(),
          style: TextStyle(
            color: match.isLive ? lime : muted,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: .8,
          ),
        ),
      ],
    ),
  );
}

class Statistics extends StatelessWidget {
  const Statistics(this.match, {this.detail, super.key});
  final FootballMatch match;
  final MatchDetail? detail;

  @override
  Widget build(BuildContext context) {
    final stats = detail?.statistics.isNotEmpty == true
        ? detail!.statistics
        : match.statistics;
    if (stats.isEmpty) {
      return const EmptyState(
        'Sin estadísticas disponibles',
        'Mostraremos únicamente los datos publicados por la fuente.',
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            for (final stat in stats)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    SizedBox(
                      width: 64,
                      child: Text(
                        _statValue(stat['home'], stat['unit']),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        _statLabel(stat['label']?.toString() ?? ''),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: muted),
                      ),
                    ),
                    SizedBox(
                      width: 64,
                      child: Text(
                        _statValue(stat['away'], stat['unit']),
                        textAlign: TextAlign.end,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _statValue(dynamic value, dynamic unit) {
  final text = value?.toString() ?? '—';
  final suffix = unit?.toString() ?? '';
  return '$text$suffix';
}

String _statLabel(String value) {
  final clean = value.replaceAll('_', ' ').trim();
  if (clean.isEmpty) return 'Estadística';
  return clean
      .split(RegExp(r'\\s+'))
      .map((word) => word.isEmpty
          ? word
          : '${word[0].toUpperCase()}${word.substring(1)}')
      .join(' ');
}

class _DetailPendingCard extends StatelessWidget {
  const _DetailPendingCard({required this.onRefresh});

  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.cloud_sync_outlined,
                size: 20,
                color: muted,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Solicitamos alineaciones y estadísticas a la fuente.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Actualizar detalles'),
            ),
          ),
        ],
      ),
    ),
  );
}

class DetailIncidents extends StatelessWidget {
  const DetailIncidents(this.detail, {super.key});

  final MatchDetail detail;

  @override
  Widget build(BuildContext context) => Card(
    child: Column(
      children: [
        for (final incident in detail.incidents)
          ListTile(
            leading: SizedBox(
              width: 42,
              child: Text(
                incident['minute'] == null ? '—' : "${incident['minute']}′",
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: lime,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            title: Text(incident['detail']?.toString() ?? eventLabel(
              incident['type']?.toString() ?? '',
            )),
            subtitle: Text(incident['label']?.toString() ?? ''),
            trailing: EventBadge(incident['type']?.toString() ?? ''),
          ),
      ],
    ),
  );
}

class Lineups extends StatelessWidget {
  const Lineups(this.data, this.match, this.detail, {super.key});

  final Snapshot data;
  final FootballMatch match;
  final MatchDetail detail;

  @override
  Widget build(BuildContext context) {
    final hasPlayers =
        detail.homeStarters.isNotEmpty || detail.awayStarters.isNotEmpty;
    if (!hasPlayers) {
      return EmptyState(
        'Alineaciones no disponibles',
        detail.pending
            ? 'Ya solicitamos el detalle. Se actualizará automáticamente cuando esté disponible.'
            : 'La fuente todavía no publicó una alineación para este encuentro.',
      );
    }

    return Column(
      children: [
        _TeamLineup(
          team: data.team(match.homeId)!,
          formation: detail.homeFormation,
          starters: detail.homeStarters,
          substitutes: detail.homeSubstitutes,
        ),
        const SizedBox(height: 16),
        _TeamLineup(
          team: data.team(match.awayId)!,
          formation: detail.awayFormation,
          starters: detail.awayStarters,
          substitutes: detail.awaySubstitutes,
        ),
      ],
    );
  }
}

class _TeamLineup extends StatelessWidget {
  const _TeamLineup({
    required this.team,
    required this.formation,
    required this.starters,
    required this.substitutes,
  });

  final Entity team;
  final String? formation;
  final List<Json> starters;
  final List<Json> substitutes;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              EntityAvatar(team, size: 38),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  team.name,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              if (formation != null)
                Text(
                  formation!,
                  style: const TextStyle(
                    color: lime,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          const Text(
            'Titulares',
            style: TextStyle(color: muted, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          for (final player in starters) _PlayerRow(player),
          if (substitutes.isNotEmpty) ...[
            const Divider(height: 28),
            const Text(
              'Suplentes',
              style: TextStyle(color: muted, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            for (final player in substitutes) _PlayerRow(player),
          ],
        ],
      ),
    ),
  );
}

class _PlayerRow extends StatelessWidget {
  const _PlayerRow(this.player);
  final Json player;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        SizedBox(
          width: 30,
          child: Text(
            player['number']?.toString() ?? '—',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: muted,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            player['name']?.toString() ?? 'Jugador',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        if (player['position'] != null)
          Text(
            player['position'].toString(),
            style: const TextStyle(color: muted, fontSize: 12),
          ),
      ],
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

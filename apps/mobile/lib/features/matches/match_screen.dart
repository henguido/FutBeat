import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/interests.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';
import '../entities/standings.dart';

class MatchScreen extends ConsumerStatefulWidget {
  const MatchScreen({super.key, required this.id, this.initialData});

  final String id;
  final Snapshot? initialData;

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
  Widget build(BuildContext context) {
    final updates =
        ref.watch(liveMatchUpdatesProvider).asData?.value ??
        const <String, LiveMatchUpdate>{};
    final initialData = widget.initialData;
    if (initialData != null) {
      return _buildMatchCenter(initialData.withLiveUpdates(updates));
    }

    return ref
        .watch(matchContextSnapshotProvider(widget.id))
        .when(
          loading: () => Scaffold(
            appBar: AppBar(title: const Text('Match Center')),
            body: const Center(child: CircularProgressIndicator()),
          ),
          error: (_, stack) => Scaffold(
            appBar: AppBar(title: const Text('Match Center')),
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const EmptyState(
                    'No pudimos cargar este partido',
                    'Revisa tu conexión e intenta nuevamente.',
                    icon: Icons.cloud_off,
                  ),
                  FilledButton(
                    onPressed: () async {
                      ref.invalidate(matchContextSnapshotProvider(widget.id));
                      try {
                        await ref.read(
                          matchContextSnapshotProvider(widget.id).future,
                        );
                      } catch (_) {
                        // Keep the recoverable error state visible.
                      }
                    },
                    child: const Text('Reintentar'),
                  ),
                ],
              ),
            ),
          ),
          data: (data) => _buildMatchCenter(data.withLiveUpdates(updates)),
        );
  }

  Widget _buildMatchCenter(Snapshot data) {
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

    final competition = data.competition(match.competitionId);
    if (competition == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Partido')),
        body: const EmptyState(
          'Competición no disponible',
          'Vuelve a Partidos e intenta nuevamente.',
        ),
      );
    }

    final detail =
        ref.watch(matchDetailProvider(widget.id)).asData?.value ??
        MatchDetail.empty(widget.id);
    final venue = detail.stadium ?? match.json['venue']?.toString() ?? '';

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
                MatchHero(
                  data: data,
                  match: match,
                  competition: competition,
                  detail: detail,
                  venue: venue,
                ),
                if (detail.videos.isNotEmpty) ...[
                  heading(context, 'Resumen oficial'),
                  PostMatchVideos(detail),
                ],
                heading(context, 'Eventos del partido'),
                MatchTimeline(data, match, detail),
                heading(context, 'Estadísticas clave'),
                Statistics(match, detail: detail),
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
  }
}

class MatchHero extends StatelessWidget {
  const MatchHero({
    required this.data,
    required this.match,
    required this.competition,
    required this.detail,
    required this.venue,
    super.key,
  });

  final Snapshot data;
  final FootballMatch match;
  final Entity competition;
  final MatchDetail detail;
  final String venue;

  @override
  Widget build(BuildContext context) {
    final home = data.team(match.homeId)!;
    final away = data.team(match.awayId)!;

    Widget team(Entity entity) => Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => context.push('/team/${entity.id}'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Column(
            children: [
              EntityAvatar(entity, size: 58),
              const SizedBox(height: 8),
              Text(
                entity.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
        child: Column(
          children: [
            TextButton(
              onPressed: () => context.push('/competition/${competition.id}'),
              child: Text(competition.name, textAlign: TextAlign.center),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                team(home),
                SizedBox(
                  width: 112,
                  child: Column(
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          match.score,
                          style: const TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: _MatchStatePill(match),
                      ),
                    ],
                  ),
                ),
                team(away),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '${match.startTime.day}/${match.startTime.month} · '
              '${localTime(context, match.startTime)} · Hora local',
              style: const TextStyle(color: muted, fontSize: 12),
              textAlign: TextAlign.center,
            ),
            if (venue.trim().isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(
                venue,
                style: const TextStyle(color: muted, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
            if (detail.referee != null || detail.round != null) ...[
              const SizedBox(height: 5),
              Text(
                [
                  if (detail.round != null) 'Jornada ${detail.round}',
                  if (detail.referee != null) 'Árbitro: ${detail.referee}',
                ].join(' · '),
                textAlign: TextAlign.center,
                style: const TextStyle(color: muted, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MatchStatePill extends StatelessWidget {
  const _MatchStatePill(this.match);

  final FootballMatch match;

  @override
  Widget build(BuildContext context) {
    final label = match.statusLabel;
    if (label.isEmpty) return const SizedBox.shrink();

    return Container(
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
            label.toUpperCase(),
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
}

class PostMatchVideos extends StatelessWidget {
  const PostMatchVideos(this.detail, {super.key});

  final MatchDetail detail;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final video in detail.videos)
        Card(
          child: ListTile(
            leading: const CircleAvatar(child: Icon(Icons.play_arrow_rounded)),
            title: Text(
              video['title']?.toString() ?? 'Resumen del partido',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              [
                video['channelName']?.toString() ?? '',
                video['source']?.toString() ?? '',
              ].where((value) => value.trim().isNotEmpty).join(' · '),
            ),
            trailing: IconButton(
              tooltip: 'Copiar enlace de YouTube',
              icon: const Icon(Icons.link),
              onPressed: () async {
                final url = video['url']?.toString() ?? '';
                if (!url.startsWith('https://www.youtube.com/watch?v=')) return;
                await Clipboard.setData(ClipboardData(text: url));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Enlace de YouTube copiado')),
                );
              },
            ),
          ),
        ),
    ],
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
      if (detail?.pending == true) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 28),
          child: Center(child: CircularProgressIndicator()),
        );
      }
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text('Sin estadísticas', style: TextStyle(color: muted)),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [for (final stat in stats) _StatisticComparison(stat)],
        ),
      ),
    );
  }
}

class _StatisticComparison extends StatelessWidget {
  const _StatisticComparison(this.stat);

  final Json stat;

  @override
  Widget build(BuildContext context) {
    final home = statNumericValue(stat['home']);
    final away = statNumericValue(stat['away']);
    final total = (home ?? 0) + (away ?? 0);
    final ratio = total > 0 ? (home ?? 0) / total : null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        children: [
          Row(
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
          if (ratio != null) ...[
            const SizedBox(height: 7),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: ratio.clamp(0, 1).toDouble(),
                minHeight: 5,
                backgroundColor: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

double? statNumericValue(dynamic value) {
  if (value is num) return value.toDouble();
  final raw = value?.toString().trim().replaceAll('%', '') ?? '';
  return double.tryParse(raw);
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
      .map(
        (word) => word.isEmpty
            ? word
            : '${word[0].toUpperCase()}${word.substring(1)}',
      )
      .join(' ');
}

class MatchTimeline extends StatelessWidget {
  const MatchTimeline(this.data, this.match, this.detail, {super.key});

  final Snapshot data;
  final FootballMatch match;
  final MatchDetail detail;

  @override
  Widget build(BuildContext context) {
    final timeline = mergedMatchTimeline(match, detail);
    if (timeline.isEmpty) {
      if (detail.pending) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 28),
          child: Center(child: CircularProgressIndicator()),
        );
      }
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text('Sin eventos', style: TextStyle(color: muted)),
        ),
      );
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (final event in timeline)
            Builder(
              builder: (context) {
                final type = event['type']?.toString() ?? '';
                final team = data.team(event['teamId']?.toString() ?? '');
                final player = data.player(event['playerId']?.toString() ?? '');
                final rawDetail = event['detail']?.toString().trim() ?? '';
                final rawLabel = event['label']?.toString().trim() ?? '';
                final rawTeam = event['team']?.toString().trim() ?? '';
                final title =
                    player?.name ??
                    (rawDetail.isNotEmpty
                        ? rawDetail
                        : rawLabel.isNotEmpty
                        ? rawLabel
                        : eventLabel(type));
                final subtitle = <String>[
                  eventLabel(type),
                  if (team != null)
                    team.name
                  else if (rawTeam.isNotEmpty)
                    rawTeam,
                  if (rawLabel.isNotEmpty &&
                      rawLabel != title &&
                      rawLabel != eventLabel(type))
                    rawLabel,
                ];

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
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(subtitle.join(' · ')),
                  trailing: EventBadge(type),
                  onTap: player == null
                      ? null
                      : () => context.push('/player/${event['playerId']}'),
                );
              },
            ),
        ],
      ),
    );
  }
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
      if (detail.pending) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 28),
          child: Center(child: CircularProgressIndicator()),
        );
      }
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text('Sin alineaciones', style: TextStyle(color: muted)),
        ),
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
  Widget build(BuildContext context) {
    final pitchRows = formationPlayerRows(formation, starters);
    return Card(
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
            const SizedBox(height: 8),
            if (pitchRows != null)
              _FormationPitch(pitchRows)
            else
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
}

List<List<Json>>? formationPlayerRows(String? formation, List<Json> starters) {
  if (formation == null || starters.length != 11) return null;
  final parts = formation
      .split('-')
      .map(int.tryParse)
      .whereType<int>()
      .where((value) => value > 0)
      .toList();
  if (parts.isEmpty || parts.fold<int>(1, (sum, value) => sum + value) != 11) {
    return null;
  }

  final ordered = [...starters]
    ..sort(
      (a, b) => (a['lineupPosition'] as num? ?? 999).compareTo(
        b['lineupPosition'] as num? ?? 999,
      ),
    );

  var offset = 1;
  final rows = <List<Json>>[
    [ordered.first],
  ];
  for (final size in parts) {
    rows.add(ordered.sublist(offset, offset + size));
    offset += size;
  }
  return rows.reversed.toList();
}

class _FormationPitch extends StatelessWidget {
  const _FormationPitch(this.rows);

  final List<List<Json>> rows;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 18),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: Theme.of(context).dividerColor.withValues(alpha: .35),
      ),
    ),
    child: Column(
      children: [
        for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final player in rows[rowIndex])
                Expanded(child: _PitchPlayer(player)),
            ],
          ),
          if (rowIndex != rows.length - 1) const SizedBox(height: 18),
        ],
      ],
    ),
  );
}

class _PitchPlayer extends StatelessWidget {
  const _PitchPlayer(this.player);

  final Json player;

  @override
  Widget build(BuildContext context) {
    final name = player['name']?.toString() ?? 'Jugador';
    final words = name.trim().split(RegExp(r'\s+'));
    final shortName = words.length > 1 ? words.last : name;

    return Column(
      children: [
        CircleAvatar(
          radius: 19,
          child: Text(
            player['number']?.toString() ?? '—',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          shortName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
        ),
        if (player['number'] != null)
          Text(
            '#${player['number']}',
            style: const TextStyle(fontSize: 10, color: muted),
          ),
      ],
    );
  }
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
            style: const TextStyle(color: muted, fontWeight: FontWeight.w700),
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

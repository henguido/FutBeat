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
  final Set<String> _recordedTeamInterests = {};
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

    for (final teamId in [match.homeId, match.awayId]) {
      if (_recordedTeamInterests.add(teamId)) {
        Future.microtask(() => recordTemporaryInterest(ref, 'team', teamId));
      }
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
          coach: detail.homeCoach,
          incidents: detail.incidents,
          side: 'home',
        ),
        const SizedBox(height: 16),
        _TeamLineup(
          team: data.team(match.awayId)!,
          formation: detail.awayFormation,
          starters: detail.awayStarters,
          substitutes: detail.awaySubstitutes,
          coach: detail.awayCoach,
          incidents: detail.incidents,
          side: 'away',
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
    required this.coach,
    required this.incidents,
    required this.side,
  });

  final Entity team;
  final String? formation;
  final List<Json> starters;
  final List<Json> substitutes;
  final Json? coach;
  final List<Json> incidents;
  final String side;

  @override
  Widget build(BuildContext context) {
    final pitchRows = adaptiveFormationRows(formation, starters);
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
            if (starters.isNotEmpty) ...[
              const Text(
                'Titulares',
                style: TextStyle(color: muted, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              _FormationPitch(pitchRows, incidents: incidents, side: side),
            ],
            if (substitutes.isNotEmpty) ...[
              const Divider(height: 28),
              const Text(
                'Suplentes',
                style: TextStyle(color: muted, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 460 ? 3 : 2;
                  return GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: substitutes.length,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisExtent: 82,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemBuilder: (_, index) => _BenchPlayer(
                      substitutes[index],
                      events: lineupEventsForPlayer(
                        substitutes[index],
                        incidents,
                        side,
                      ),
                    ),
                  );
                },
              ),
            ],
            if (coach != null) ...[
              const Divider(height: 28),
              const Text(
                'Entrenador',
                style: TextStyle(color: muted, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              _CoachTile(coach!),
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

List<List<Json>> adaptiveFormationRows(String? formation, List<Json> starters) {
  final declared = formationPlayerRows(formation, starters);
  if (declared != null) return declared;
  if (starters.isEmpty) return const [];

  final ordered = [...starters]
    ..sort(
      (a, b) => (a['lineupPosition'] as num? ?? 999).compareTo(
        b['lineupPosition'] as num? ?? 999,
      ),
    );
  final groups = <int, List<Json>>{};
  for (final player in ordered) {
    groups.putIfAbsent(_positionBand(player['position']), () => []).add(player);
  }
  if (groups.length > 1) {
    return [
      for (final key in groups.keys.toList()..sort((a, b) => b - a))
        groups[key]!,
    ];
  }

  final rows = <List<Json>>[];
  for (var index = 0; index < ordered.length; index += 4) {
    rows.add(ordered.sublist(index, (index + 4).clamp(0, ordered.length)));
  }
  return rows.reversed.toList();
}

int _positionBand(dynamic raw) {
  final value = raw?.toString().toLowerCase() ?? '';
  if (value.contains('goal') || value == 'gk' || value.contains('portero')) {
    return 0;
  }
  if (value.contains('def') ||
      value == 'cb' ||
      value == 'lb' ||
      value == 'rb') {
    return 1;
  }
  if (value.contains('mid') || value.contains('medio') || value == 'cm') {
    return 2;
  }
  if (value.contains('for') ||
      value.contains('att') ||
      value.contains('wing')) {
    return 3;
  }
  return 2;
}

class LineupPlayerEvent {
  const LineupPlayerEvent(this.type, this.minute, {this.role});
  final String type;
  final int? minute;
  final String? role;
}

List<LineupPlayerEvent> lineupEventsForPlayer(
  Json player,
  List<Json> incidents,
  String side,
) {
  final id = player['id']?.toString().trim();
  if (id == null || id.isEmpty) return const [];
  final result = <LineupPlayerEvent>[];
  for (final incident in incidents) {
    final incidentSide =
        incident['side']?.toString() ?? incident['team']?.toString() ?? '';
    if (incidentSide.isNotEmpty && incidentSide != side) continue;
    final type = incident['type']?.toString() ?? 'OTHER';
    final minute = incident['minute'] as int?;
    if (incident['playerId']?.toString() == id) {
      result.add(LineupPlayerEvent(type, minute));
    }
    if (incident['assistPlayerId']?.toString() == id) {
      result.add(LineupPlayerEvent('ASSIST', minute));
    }
    if (incident['outPlayerId']?.toString() == id) {
      result.add(LineupPlayerEvent('SUB_OUT', minute, role: 'out'));
    }
    if (incident['inPlayerId']?.toString() == id) {
      result.add(LineupPlayerEvent('SUB_IN', minute, role: 'in'));
    }
  }
  return result;
}

class _FormationPitch extends StatelessWidget {
  const _FormationPitch(
    this.rows, {
    required this.incidents,
    required this.side,
  });

  final List<List<Json>> rows;
  final List<Json> incidents;
  final String side;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(18),
    child: CustomPaint(
      painter: const _PitchPainter(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 22),
        constraints: BoxConstraints(
          minHeight: (rows.length >= 4 ? 410 : 100 + rows.length * 82)
              .toDouble(),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (final row in rows)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final player in row)
                    Expanded(
                      child: _PitchPlayer(
                        player,
                        events: lineupEventsForPlayer(player, incidents, side),
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

class _PitchPainter extends CustomPainter {
  const _PitchPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final grass = Paint()..color = const Color(0xFF123F35);
    canvas.drawRect(Offset.zero & size, grass);
    final stripe = Paint()..color = const Color(0x0AFFFFFF);
    for (var i = 0; i < 8; i += 2) {
      canvas.drawRect(
        Rect.fromLTWH(0, size.height * i / 8, size.width, size.height / 8),
        stripe,
      );
    }
    final line = Paint()
      ..color = Colors.white.withValues(alpha: .28)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final field = Rect.fromLTWH(10, 10, size.width - 20, size.height - 20);
    canvas.drawRect(field, line);
    canvas.drawLine(
      Offset(10, size.height / 2),
      Offset(size.width - 10, size.height / 2),
      line,
    );
    canvas.drawCircle(Offset(size.width / 2, size.height / 2), 34, line);
    canvas.drawRect(
      Rect.fromCenter(
        center: Offset(size.width / 2, 10),
        width: size.width * .48,
        height: 70,
      ),
      line,
    );
    canvas.drawRect(
      Rect.fromCenter(
        center: Offset(size.width / 2, size.height - 10),
        width: size.width * .48,
        height: 70,
      ),
      line,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _PitchPlayer extends StatelessWidget {
  const _PitchPlayer(this.player, {required this.events});

  final Json player;
  final List<LineupPlayerEvent> events;

  @override
  Widget build(BuildContext context) {
    final name = player['name']?.toString() ?? 'Jugador';
    final words = name.trim().split(RegExp(r'\s+'));
    final shortName = words.length > 1 ? words.last : name;

    return Column(
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            _PlayerAvatar(player, size: 43),
            if (player['rating'] is num)
              Positioned(
                right: -6,
                top: -5,
                child: _RatingBadge(player['rating'] as num),
              ),
            if (player['captain'] == true)
              const Positioned(left: -5, top: -5, child: _CaptainBadge()),
          ],
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
        if (events.isNotEmpty) ...[
          const SizedBox(height: 3),
          _PlayerEvents(events),
        ],
      ],
    );
  }
}

class _BenchPlayer extends StatelessWidget {
  const _BenchPlayer(this.player, {required this.events});
  final Json player;
  final List<LineupPlayerEvent> events;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest
          .withValues(alpha: .55),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(
        color: Theme.of(context).dividerColor.withValues(alpha: .2),
      ),
    ),
    child: Row(
      children: [
        _PlayerAvatar(player, size: 42),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                player['name']?.toString() ?? 'Jugador',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                [
                  if (player['number'] != null) '#${player['number']}',
                  if (player['position'] != null) player['position'].toString(),
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: muted, fontSize: 10),
              ),
              if (events.isNotEmpty) _PlayerEvents(events),
            ],
          ),
        ),
        if (player['rating'] is num) _RatingBadge(player['rating'] as num),
      ],
    ),
  );
}

class _CoachTile extends StatelessWidget {
  const _CoachTile(this.coach);
  final Json coach;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest
          .withValues(alpha: .4),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      children: [
        _PlayerAvatar(coach, size: 38),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            coach['name']?.toString() ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
  );
}

class _PlayerAvatar extends StatelessWidget {
  const _PlayerAvatar(this.player, {required this.size});
  final Json player;
  final double size;

  @override
  Widget build(BuildContext context) {
    final image = player['image']?.toString();
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF202D2A),
        border: Border.all(color: lime.withValues(alpha: .55)),
      ),
      child: Text(
        player['number']?.toString() ?? _playerInitials(player['name']),
        style: TextStyle(fontSize: size * .27, fontWeight: FontWeight.w900),
      ),
    );
    if (image == null || image.isEmpty) return fallback;
    return ClipOval(
      child: Image.network(
        image,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, error, stack) => fallback,
      ),
    );
  }
}

String _playerInitials(dynamic name) {
  final words =
      name?.toString().trim().split(RegExp(r'\s+')) ?? const <String>[];
  return words
      .where((word) => word.isNotEmpty)
      .take(2)
      .map((word) => word[0])
      .join()
      .toUpperCase();
}

class _RatingBadge extends StatelessWidget {
  const _RatingBadge(this.rating);
  final num rating;

  @override
  Widget build(BuildContext context) {
    final value = rating.toDouble();
    final color = value >= 8
        ? lime
        : value >= 7
        ? Colors.amber
        : Colors.orangeAccent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        value.toStringAsFixed(1),
        style: const TextStyle(
          color: Colors.black,
          fontSize: 9,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _CaptainBadge extends StatelessWidget {
  const _CaptainBadge();
  @override
  Widget build(BuildContext context) => Container(
    width: 18,
    height: 18,
    alignment: Alignment.center,
    decoration: const BoxDecoration(
      color: Colors.white,
      shape: BoxShape.circle,
    ),
    child: const Text(
      'C',
      style: TextStyle(
        color: Colors.black,
        fontSize: 10,
        fontWeight: FontWeight.w900,
      ),
    ),
  );
}

class _PlayerEvents extends StatelessWidget {
  const _PlayerEvents(this.events);
  final List<LineupPlayerEvent> events;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 3,
    runSpacing: 2,
    alignment: WrapAlignment.center,
    children: [for (final event in events) _LineupEventIcon(event)],
  );
}

class _LineupEventIcon extends StatelessWidget {
  const _LineupEventIcon(this.event);
  final LineupPlayerEvent event;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (event.type) {
      'GOAL' => (Icons.sports_soccer, Colors.white),
      'ASSIST' => (Icons.assistant_rounded, lime),
      'YELLOW_CARD' => (Icons.square_rounded, Colors.amber),
      'RED_CARD' => (Icons.square_rounded, Colors.redAccent),
      'SUB_IN' => (Icons.arrow_upward_rounded, lime),
      'SUB_OUT' => (Icons.arrow_downward_rounded, Colors.redAccent),
      _ => (Icons.circle, muted),
    };
    final minute = event.minute == null ? '' : " ${event.minute}′";
    return Tooltip(
      message: '${eventLabel(event.type)}$minute',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          if (event.minute != null)
            Text(
              '${event.minute}′',
              style: const TextStyle(fontSize: 8, color: Colors.white70),
            ),
        ],
      ),
    );
  }
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
  'SUB_IN' => 'Entró',
  'SUB_OUT' => 'Salió',
  'ASSIST' => 'Asistencia',
  'VAR' => 'VAR',
  'MISSED_PENALTY' => 'Penal fallado',
  'KICKOFF' => 'Inicio',
  'HALFTIME' => 'Medio tiempo',
  'FULL_TIME' => 'Final',
  _ => 'Evento',
};

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';
import '../matches/match_screen.dart';
import '../matches/matches_screen.dart';
import 'profile_widgets.dart';
import 'team_profile.dart';

const _singularPosition = {
  'Porteros': 'Portero',
  'Defensas': 'Defensa',
  'Mediocampistas': 'Mediocampista',
  'Delanteros': 'Delantero',
};

int? playerShirtNumber(Entity player) {
  final value = player.json['shirtNumber'] ?? player.json['number'];
  if (value is int) return value;
  return int.tryParse(value?.toString() ?? '');
}

/// First present, non-empty value among [keys] of [json].
Object? _pick(Json json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value == null) continue;
    if (value is String && value.trim().isEmpty) continue;
    return value;
  }
  return null;
}

String? _count(Object? value) {
  if (value is int) return '$value';
  if (value is num) {
    return value == value.roundToDouble() ? '${value.toInt()}' : '$value';
  }
  if (value is String && RegExp(r'^\d+$').hasMatch(value.trim())) {
    return value.trim();
  }
  return null;
}

/// Real season numbers published for the player, never derived from matches.
/// Reads a `seasonStats` object when present, else the squad's top-level fields.
class PlayerSeason {
  const PlayerSeason(this.title, this.rows);

  final String? title;
  final List<(IconData, String, String)> rows;

  bool get isEmpty => rows.isEmpty;
}

PlayerSeason playerSeason(Entity player) {
  final nested = player.json['seasonStats'];
  final json = nested is Map ? Json.from(nested) : player.json;
  String? rating() {
    final value = _pick(json, ['rating']);
    final number = value is num ? value : num.tryParse('${value ?? ''}');
    return number?.toStringAsFixed(1);
  }

  final rows = <(IconData, String, String)>[
    for (final (icon, label, keys) in [
      (
        Icons.sports_soccer,
        'Partidos',
        ['matchesPlayed', 'appearances', 'matches'],
      ),
      (
        Icons.play_circle_outline,
        'Titularidades',
        ['starts', 'lineups', 'gamesStarted'],
      ),
      (Icons.timer_outlined, 'Minutos', ['minutesPlayed', 'minutes']),
      (Icons.sports_score, 'Goles', ['goals']),
      (Icons.assistant_outlined, 'Asistencias', ['assists']),
      (Icons.square_rounded, 'Amarillas', ['yellowCards', 'yellow']),
      (Icons.square_rounded, 'Rojas', ['redCards', 'red']),
    ])
      if (_count(_pick(json, keys)) case final value?) (icon, label, value),
    if (rating() case final value?) (Icons.star_outline, 'Rating', value),
  ];
  final title =
      [
            _pick(json, ['competitionName', 'competition']),
            _pick(json, ['seasonName', 'season']),
          ]
          .whereType<Object>()
          .map((value) => '$value'.trim())
          .where((v) => v.isNotEmpty);
  return PlayerSeason(title.isEmpty ? null : title.join(' · '), rows);
}

/// Provider season numbers, kept for the Estadísticas tab.
List<(IconData, String, String)> playerStatRows(Entity player) =>
    playerSeason(player).rows;

const _positionNames = {
  'goalkeeper': 'Portero',
  'goalkeepers': 'Portero',
  'gk': 'Portero',
  'centreback': 'Defensa central',
  'centerback': 'Defensa central',
  'cb': 'Defensa central',
  'leftback': 'Lateral izquierdo',
  'lb': 'Lateral izquierdo',
  'rightback': 'Lateral derecho',
  'rb': 'Lateral derecho',
  'leftwingback': 'Carrilero izquierdo',
  'rightwingback': 'Carrilero derecho',
  'defensivemidfield': 'Mediocentro defensivo',
  'defensivemidfielder': 'Mediocentro defensivo',
  'dm': 'Mediocentro defensivo',
  'centralmidfield': 'Mediocentro',
  'centralmidfielder': 'Mediocentro',
  'cm': 'Mediocentro',
  'attackingmidfield': 'Mediapunta',
  'attackingmidfielder': 'Mediapunta',
  'am': 'Mediapunta',
  'leftmidfield': 'Interior izquierdo',
  'leftmidfielder': 'Interior izquierdo',
  'rightmidfield': 'Interior derecho',
  'rightmidfielder': 'Interior derecho',
  'leftwinger': 'Extremo izquierdo',
  'leftwing': 'Extremo izquierdo',
  'lw': 'Extremo izquierdo',
  'rightwinger': 'Extremo derecho',
  'rightwing': 'Extremo derecho',
  'rw': 'Extremo derecho',
  'centreforward': 'Delantero centro',
  'centerforward': 'Delantero centro',
  'striker': 'Delantero centro',
  'st': 'Delantero centro',
  'cf': 'Delantero centro',
  'secondstriker': 'Segundo delantero',
};

/// Pitch spots (x: left→right, y: attack→own goal), 0..1.
const _positionSpots = {
  'Portero': Offset(.5, .9),
  'Defensa': Offset(.5, .72),
  'Defensa central': Offset(.5, .72),
  'Lateral izquierdo': Offset(.14, .68),
  'Lateral derecho': Offset(.86, .68),
  'Carrilero izquierdo': Offset(.12, .56),
  'Carrilero derecho': Offset(.88, .56),
  'Mediocentro defensivo': Offset(.5, .58),
  'Mediocampista': Offset(.5, .48),
  'Mediocentro': Offset(.5, .48),
  'Interior izquierdo': Offset(.2, .44),
  'Interior derecho': Offset(.8, .44),
  'Mediapunta': Offset(.5, .34),
  'Extremo izquierdo': Offset(.18, .22),
  'Extremo derecho': Offset(.82, .22),
  'Segundo delantero': Offset(.5, .22),
  'Delantero': Offset(.5, .14),
  'Delantero centro': Offset(.5, .12),
};

/// Spanish position; detailed names first, then the squad classifier.
String playerPositionText(Object? raw) {
  final value = raw?.toString().trim() ?? '';
  if (value.isEmpty) return '';
  final key = value.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  return _positionNames[key] ??
      _singularPosition[squadGroupOf(value)] ??
      playerPositionLabel(value);
}

Offset? positionSpot(String spanish) => _positionSpots[spanish];

/// Main position plus real secondary positions (deduplicated, in Spanish).
(String, List<String>) playerPositions(Entity player) {
  final main = playerPositionText(player.json['position']);
  final raw = _pick(player.json, [
    'secondaryPositions',
    'otherPositions',
    'positions',
  ]);
  final secondary = <String>[
    if (raw is List)
      for (final item in raw)
        playerPositionText(
          item is Map ? item['name'] ?? item['position'] : item,
        ),
  ].where((value) => value.isNotEmpty && value != main).toSet().toList();
  return (main, secondary);
}

String _formatDate(String raw) {
  final date = DateTime.tryParse(raw);
  if (date == null) return raw;
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(date.day)}/${two(date.month)}/${date.year}';
}

String? _height(Json json) {
  final value = _pick(json, ['height', 'heightCm']);
  if (value is num) return '${value.round()} cm';
  if (value is String) {
    final text = value.trim();
    return RegExp(r'^\d{2,3}$').hasMatch(text) ? '$text cm' : text;
  }
  return null;
}

String? _foot(Json json) {
  final value = _pick(json, ['preferredFoot', 'foot'])?.toString().trim();
  if (value == null) return null;
  return switch (value.toLowerCase()) {
    'right' || 'derecho' => 'Derecho',
    'left' || 'izquierdo' => 'Izquierdo',
    'both' || 'ambos' || 'ambidextrous' => 'Ambos',
    _ => value,
  };
}

String _compact(num value) {
  String trim(num v) {
    final text = v.toStringAsFixed(1);
    return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
  }

  if (value >= 1000000) return '${trim(value / 1000000)} M';
  if (value >= 1000) return '${trim(value / 1000)} mil';
  return trim(value);
}

/// Market value exactly as published: a currency is shown only when given.
String? _marketValue(Json json) {
  final value = _pick(json, ['marketValue', 'value']);
  if (value is String) return value.trim();
  if (value is num) {
    final currency = _pick(json, [
      'marketValueCurrency',
      'currency',
    ])?.toString();
    return [?currency, _compact(value)].join(' ');
  }
  if (value is Map) {
    final amount = value['amount'] ?? value['value'];
    if (amount is! num) return null;
    final currency = value['currency']?.toString();
    return [
      if (currency != null && currency.isNotEmpty) currency,
      _compact(amount),
    ].join(' ');
  }
  return null;
}

/// Player sheet: only fields that really exist in the payload.
List<(String, String)> playerFacts(Entity player) {
  final json = player.json;
  final number = playerShirtNumber(player);
  final age = json['age'];
  final birth = _pick(json, ['dateOfBirth', 'birthDate'])?.toString().trim();
  final nationality =
      (_pick(json, ['nationality'])?.toString() ?? player.country).trim();
  final position = playerPositionText(json['position']);
  return [
    if (_height(json) case final height?) (height, 'Altura'),
    if (age is int) ('$age años', 'Edad'),
    if (birth != null && birth.isNotEmpty) (_formatDate(birth), 'Nacimiento'),
    if (nationality.isNotEmpty) (nationality, 'Nacionalidad'),
    if (number != null) ('$number', 'Dorsal'),
    if (_foot(json) case final foot?) (foot, 'Pie preferido'),
    if (_marketValue(json) case final value?) (value, 'Valor de mercado'),
    if (position.isNotEmpty) (position, 'Posición'),
  ];
}

/// Stored events where this player scored, assisted or was booked/subbed.
List<(FootballMatch, Json, bool)> playerRecentEvents(
  Snapshot data,
  String playerId,
) {
  final result = <(FootballMatch, Json, bool)>[];
  for (final match in data.matches) {
    for (final event in match.events) {
      if (event['playerId']?.toString() == playerId) {
        result.add((match, event, false));
      } else if (event['assistPlayerId']?.toString() == playerId &&
          event['type'] == 'GOAL') {
        result.add((match, event, true));
      }
    }
  }
  result.sort((a, b) {
    final byDate = b.$1.startTime.compareTo(a.$1.startTime);
    if (byDate != 0) return byDate;
    return (b.$2['minute'] as int? ?? 0).compareTo(a.$2['minute'] as int? ?? 0);
  });
  return result;
}

class PlayerProfileView extends StatelessWidget {
  const PlayerProfileView({
    required this.data,
    required this.player,
    required this.team,
    required this.matches,
    super.key,
  });

  final Snapshot data;
  final Entity player;
  final Entity? team;
  final List<FootballMatch> matches;

  @override
  Widget build(BuildContext context) {
    final stats = playerStatRows(player);
    final transfers = data.transfers
        .where(
          (transfer) =>
              transfer['playerId'] == null || transfer['playerId'] == player.id,
        )
        .toList();
    final tabs = [
      'Resumen',
      'Partidos',
      if (stats.length >= 2) 'Estadísticas',
      'Noticias',
      'Transferencias',
    ];

    Widget body(String tab) => switch (tab) {
      'Resumen' => ProfileTabList('resumen', [
        if (data.demo) const DemoNotice(),
        ..._summary(),
      ]),
      'Partidos' => ProfileTabList('partidos', [
        if (data.demo) const DemoNotice(),
        ..._matchList(),
      ]),
      'Estadísticas' => ProfileTabList('estadisticas', [
        if (data.demo) const DemoNotice(),
        const ProfileSectionTitle('Temporada'),
        ProfileInfoCard(stats),
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 6, 4, 0),
          child: Text(
            'Datos publicados por el proveedor de la plantilla.',
            style: TextStyle(color: muted, fontSize: 12),
          ),
        ),
      ]),
      'Noticias' => ProfileTabList('noticias', [
        if (data.demo) const DemoNotice(),
        if (data.news.isEmpty)
          const InlineEmpty(Icons.article_outlined, 'Sin noticias disponibles')
        else
          for (final article in data.news) NewsArticleCard(article),
      ]),
      _ => ProfileTabList('transferencias', [
        if (data.demo) const DemoNotice(),
        if (transfers.isEmpty)
          const InlineEmpty(
            Icons.swap_horiz,
            'Sin transferencias registradas',
            detail: 'Los cambios aparecen cuando una plantilla los confirma.',
          )
        else ...[
          const ProfileSectionTitle('Cambios de equipo'),
          for (final transfer in transfers) PlayerTransferRow(transfer),
        ],
      ]),
    };

    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            player.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          backgroundColor: profileHeaderTop,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          actions: [FollowButton('player', player.id)],
        ),
        body: NestedScrollView(
          headerSliverBuilder: (context, _) => [
            SliverToBoxAdapter(
              child: PlayerHeader(player: player, team: team),
            ),
            SliverOverlapAbsorber(
              handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
              sliver: SliverPersistentHeader(
                pinned: true,
                delegate: ProfileTabBarHeader(profileTabBar(tabs)),
              ),
            ),
          ],
          body: TabBarView(children: [for (final tab in tabs) body(tab)]),
        ),
      ),
    );
  }

  List<Widget> _summary() {
    final facts = playerFacts(player);
    final (mainPosition, secondary) = playerPositions(player);
    final season = playerSeason(player);
    final events = playerRecentEvents(data, player.id).take(5).toList();
    return [
      const ProfileSectionTitle('Ficha del jugador'),
      if (player.json['injured'] == true) const _InjuryBanner(),
      if (facts.isEmpty)
        const InlineEmpty(Icons.info_outline, 'Datos no disponibles')
      else
        PlayerFactsGrid(facts),
      if (mainPosition.isNotEmpty) ...[
        const ProfileSectionTitle('Posición'),
        PlayerPositionCard(main: mainPosition, secondary: secondary),
      ],
      if (!season.isEmpty) ...[
        const ProfileSectionTitle('Temporada actual'),
        PlayerSeasonCard(season),
      ],
      const ProfileSectionTitle('Equipo actual'),
      if (team != null)
        EntityTile(team!, 'team')
      else
        const InlineEmpty(Icons.shield_outlined, 'Equipo no disponible'),
      if (events.isNotEmpty) ...[
        const ProfileSectionTitle('Actividad reciente'),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (final (match, event, assist) in events)
                PlayerEventRow(
                  data: data,
                  match: match,
                  event: event,
                  assist: assist,
                ),
            ],
          ),
        ),
      ],
    ];
  }

  List<Widget> _matchList() {
    if (matches.isEmpty) {
      return const [
        InlineEmpty(Icons.event_busy_outlined, 'Sin partidos disponibles'),
      ];
    }
    final upcoming = matches.where((m) => !m.isFinished).toList();
    final results = matches.where((m) => m.isFinished).toList().reversed;
    Widget dated(FootballMatch match) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 4),
            child: Text(
              '${matchDayLabel(match.startTime)} · ${match.startTime.year}',
              style: const TextStyle(color: muted, fontSize: 12),
            ),
          ),
          MatchCard(match, data),
        ],
      ),
    );
    return [
      if (upcoming.isNotEmpty) ...[
        const ProfileSectionTitle('Próximos'),
        for (final match in upcoming) dated(match),
      ],
      if (results.isNotEmpty) ...[
        const ProfileSectionTitle('Resultados'),
        for (final match in results) dated(match),
      ],
    ];
  }
}

class PlayerHeader extends StatelessWidget {
  const PlayerHeader({required this.player, required this.team, super.key});

  final Entity player;
  final Entity? team;

  @override
  Widget build(BuildContext context) {
    final number = playerShirtNumber(player);
    final position = playerPositionText(player.json['position']);
    final age = player.json['age'];
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [profileHeaderTop, profileHeaderBottom],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Row(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: lime.withValues(alpha: .6),
                    width: 2,
                  ),
                ),
                child: PlayerPhoto(player, size: 84),
              ),
              if (number != null)
                Positioned(
                  right: -4,
                  bottom: -2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: lime,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '#$number',
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  player.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 22,
                    height: 1.15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (team != null)
                      ProfileHeaderChip(
                        icon: Icons.shield_outlined,
                        label: team!.name,
                        onTap: () => context.push('/team/${team!.id}'),
                      )
                    else
                      const ProfileHeaderChip(
                        icon: Icons.shield_outlined,
                        label: 'Sin equipo',
                      ),
                    if (position.isNotEmpty)
                      ProfileHeaderChip(
                        icon: Icons.sports_soccer,
                        label: position,
                      ),
                    if (player.country.isNotEmpty)
                      ProfileHeaderChip(
                        icon: Icons.public,
                        label: player.country,
                      ),
                    if (age is int)
                      ProfileHeaderChip(
                        icon: Icons.cake_outlined,
                        label: '$age años',
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class PlayerEventRow extends StatelessWidget {
  const PlayerEventRow({
    required this.data,
    required this.match,
    required this.event,
    required this.assist,
    super.key,
  });

  final Snapshot data;
  final FootballMatch match;
  final Json event;
  final bool assist;

  @override
  Widget build(BuildContext context) {
    final type = assist ? 'ASSIST' : event['type']?.toString() ?? '';
    final home = data.team(match.homeId)?.name ?? '';
    final away = data.team(match.awayId)?.name ?? '';
    final opponent = [home, away].where((name) => name.isNotEmpty).join(' vs ');
    final color = assist ? lime : eventColor(type);
    return InkWell(
      onTap: () => context.push('/match/${match.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: .14),
              ),
              child: Icon(
                assist ? Icons.assistant_outlined : eventIcon(type),
                size: 18,
                color: color,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${eventLabel(type)} · ${eventMinuteLabel(event)}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    [
                      if (opponent.isNotEmpty) opponent,
                      matchDayLabel(match.startTime),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: muted, size: 20),
          ],
        ),
      ),
    );
  }
}

class PlayerTransferRow extends StatelessWidget {
  const PlayerTransferRow(this.transfer, {super.key});

  final Json transfer;

  @override
  Widget build(BuildContext context) {
    final from = transfer['fromTeamName']?.toString().trim().isNotEmpty == true
        ? transfer['fromTeamName'].toString().trim()
        : 'Equipo anterior';
    final to = transfer['toTeamName']?.toString().trim().isNotEmpty == true
        ? transfer['toTeamName'].toString().trim()
        : 'Equipo actual';
    final toId = transfer['toTeamId']?.toString() ?? '';
    final date = DateTime.tryParse(transfer['detectedAt']?.toString() ?? '');
    return Card(
      child: InkWell(
        onTap: toId.isEmpty ? null : () => context.push('/team/$toId'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const Icon(Icons.swap_horiz, color: lime),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Icon instead of a "→" glyph the bundled font may lack.
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            from,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 6),
                          child: Icon(
                            Icons.arrow_forward_rounded,
                            size: 16,
                            color: muted,
                            semanticLabel: 'hacia',
                          ),
                        ),
                        Flexible(
                          child: Text(
                            to,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        'Cambio detectado en plantilla',
                        if (date != null)
                          '${matchDayLabel(date.toLocal())} ${date.toLocal().year}',
                      ].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (toId.isNotEmpty)
                const Icon(Icons.chevron_right, color: muted, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _InjuryBanner extends StatelessWidget {
  const _InjuryBanner();

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: BoxDecoration(
      color: Colors.redAccent.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.redAccent.withValues(alpha: .4)),
    ),
    child: const Row(
      children: [
        Icon(Icons.healing_outlined, size: 18, color: Colors.redAccent),
        SizedBox(width: 8),
        Text(
          'Lesionado',
          style: TextStyle(
            color: Colors.redAccent,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
  );
}

/// Compact sheet: value on top, label below, two per row.
class PlayerFactsGrid extends StatelessWidget {
  const PlayerFactsGrid(this.facts, {super.key});

  final List<(String, String)> facts;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = (constraints.maxWidth - 12) / 2;
          return Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              for (final (value, label) in facts)
                SizedBox(
                  width: width,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          value,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: muted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
}

class PlayerPositionCard extends StatelessWidget {
  const PlayerPositionCard({
    required this.main,
    required this.secondary,
    super.key,
  });

  final String main;
  final List<String> secondary;

  @override
  Widget build(BuildContext context) {
    final mainSpot = positionSpot(main);
    final spots = [for (final position in secondary) ?positionSpot(position)];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Posición principal',
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    main,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (secondary.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Otras posiciones',
                      style: TextStyle(color: muted, fontSize: 12),
                    ),
                    const SizedBox(height: 2),
                    for (final position in secondary)
                      Text(
                        position,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                  ],
                ],
              ),
            ),
            if (mainSpot != null) ...[
              const SizedBox(width: 12),
              Semantics(
                label: 'Cancha con la posición $main',
                child: SizedBox(
                  key: const ValueKey('player-position-pitch'),
                  width: 88,
                  height: 120,
                  child: CustomPaint(
                    painter: _MiniPitchPainter(main: mainSpot, others: spots),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MiniPitchPainter extends CustomPainter {
  const _MiniPitchPainter({required this.main, required this.others});

  final Offset main;
  final List<Offset> others;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(10)),
      Paint()..color = const Color(0xFF17452F),
    );
    final line = Paint()
      ..color = Colors.white.withValues(alpha: .3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final field = rect.deflate(5);
    canvas.drawRect(field, line);
    canvas.drawLine(field.centerLeft, field.centerRight, line);
    canvas.drawCircle(field.center, size.width * .14, line);
    for (final y in [field.top, field.bottom]) {
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset(field.center.dx, y),
          width: field.width * .52,
          height: size.height * .22,
        ),
        line,
      );
    }
    Offset at(Offset spot) => Offset(
      field.left + field.width * spot.dx,
      field.top + field.height * spot.dy,
    );
    for (final spot in others) {
      canvas.drawCircle(
        at(spot),
        5,
        Paint()..color = Colors.white.withValues(alpha: .55),
      );
    }
    canvas.drawCircle(at(main), 7, Paint()..color = lime);
    canvas.drawCircle(
      at(main),
      7,
      Paint()
        ..color = Colors.black.withValues(alpha: .4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _MiniPitchPainter oldDelegate) =>
      oldDelegate.main != main || oldDelegate.others != others;
}

class PlayerSeasonCard extends StatelessWidget {
  const PlayerSeasonCard(this.season, {super.key});

  final PlayerSeason season;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (season.title != null) ...[
            Text(
              season.title!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
          ],
          LayoutBuilder(
            builder: (context, constraints) {
              final width = (constraints.maxWidth - 16) / 3;
              return Wrap(
                spacing: 8,
                runSpacing: 10,
                children: [
                  for (final (icon, label, value) in season.rows)
                    SizedBox(
                      width: width,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            value,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          Row(
                            children: [
                              Icon(
                                icon,
                                size: 12,
                                color: label == 'Amarillas'
                                    ? Colors.amber
                                    : label == 'Rojas'
                                    ? Colors.redAccent
                                    : muted,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: muted,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 10),
          const Text(
            'Datos publicados por el proveedor.',
            style: TextStyle(color: muted, fontSize: 11),
          ),
        ],
      ),
    ),
  );
}

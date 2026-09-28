import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';
import '../matches/matches_screen.dart';
import 'profile_widgets.dart';
import 'standings.dart';
import 'team_matches_tab.dart';

/// Squad sections in display order; "Otros" holds unclassifiable positions.
const squadGroupOrder = [
  'Porteros',
  'Defensas',
  'Mediocampistas',
  'Delanteros',
  'Otros',
];

const _groupSingular = {
  'Porteros': 'Portero',
  'Defensas': 'Defensa',
  'Mediocampistas': 'Mediocampista',
  'Delanteros': 'Delantero',
};

/// Classifies a provider position (English or Spanish, plural or singular).
String squadGroupOf(Object? position) {
  final raw = position?.toString().trim().toLowerCase() ?? '';
  if (raw.isEmpty) return 'Otros';
  bool any(List<String> keys) => keys.any(raw.contains);
  if (raw == 'gk' ||
      raw == 'g' ||
      any(['goal', 'keeper', 'porter', 'arquer'])) {
    return 'Porteros';
  }
  if (raw == 'd' ||
      raw == 'df' ||
      any(['defen', 'back', 'defens', 'lateral'])) {
    return 'Defensas';
  }
  if (raw == 'm' ||
      raw == 'mf' ||
      any(['midfield', 'medio', 'centrocamp', 'volante'])) {
    return 'Mediocampistas';
  }
  if (raw == 'f' ||
      raw == 'fw' ||
      any(['forward', 'attack', 'striker', 'wing', 'delanter', 'extremo'])) {
    return 'Delanteros';
  }
  return 'Otros';
}

int? _shirtNumber(Entity player) {
  final value = player.json['shirtNumber'] ?? player.json['number'];
  if (value is int) return value;
  return int.tryParse(value?.toString() ?? '');
}

/// Players grouped by position, each group sorted by shirt number then name.
List<(String, List<Entity>)> squadGroups(Iterable<Entity> players) {
  final groups = <String, List<Entity>>{};
  for (final player in players) {
    groups
        .putIfAbsent(squadGroupOf(player.json['position']), () => [])
        .add(player);
  }
  return [
    for (final label in squadGroupOrder)
      if (groups[label]?.isNotEmpty == true)
        (
          label,
          groups[label]!..sort((a, b) {
            final left = _shirtNumber(a), right = _shirtNumber(b);
            if (left != right) {
              if (left == null) return 1;
              if (right == null) return -1;
              return left.compareTo(right);
            }
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          }),
        ),
  ];
}

/// Competition whose table really contains this team (its own group only),
/// preferring the main one. Null: no "Tabla" tab.
String? teamTableCompetitionId(
  Snapshot data,
  List<Entity> competitions,
  String teamId,
) {
  bool shows(String id) =>
      standingsGroups(
        standingsTableFor(data, id),
        data,
        focusTeamIds: {teamId},
      )?.any((group) => group.rows.any((row) => row['teamId'] == teamId)) ==
      true;
  for (final competition in competitions) {
    if (shows(competition.id)) return competition.id;
  }
  return null;
}

class TeamProfileView extends StatelessWidget {
  const TeamProfileView({
    required this.data,
    required this.team,
    required this.competitions,
    required this.matches,
    super.key,
  });

  final Snapshot data;
  final Entity team;
  final List<Entity> competitions;
  final List<FootballMatch> matches;

  @override
  Widget build(BuildContext context) {
    final players = data.players
        .where((player) => player.json['teamId'] == team.id)
        .toList();
    final tableId = teamTableCompetitionId(data, competitions, team.id);
    final tabs = [
      'Resumen',
      'Partidos',
      if (tableId != null) 'Tabla',
      'Plantilla',
      'Noticias',
      'Transferencias',
    ];
    final tabBar = profileTabBar(tabs);

    Widget body(String tab) => switch (tab) {
      'Resumen' => ProfileTabList('resumen', [
        if (data.demo) const DemoNotice(),
        ..._summary(context, players),
      ]),
      'Partidos' => TeamMatchesTab(team: team, data: data, matches: matches),
      'Tabla' => ProfileTabList('tabla', [
        if (data.demo) const DemoNotice(),
        Standings(data, tableId!, focusTeamIds: {team.id}),
      ]),
      'Plantilla' => ProfileTabList('plantilla', [
        if (data.demo) const DemoNotice(),
        TeamSquad(players, demo: data.demo, state: data.squadState),
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
        if (data.transfers.isEmpty)
          const InlineEmpty(
            Icons.swap_horiz,
            'Sin cambios de plantilla disponibles',
          )
        else
          for (final transfer in data.transfers) TransferEventCard(transfer),
      ]),
    };

    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(team.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          backgroundColor: profileHeaderTop,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          actions: [FollowButton('team', team.id)],
        ),
        body: NestedScrollView(
          headerSliverBuilder: (context, _) => [
            SliverToBoxAdapter(
              child: TeamHeader(
                team: team,
                competition: competitions.firstOrNull,
                players: players.length,
              ),
            ),
            SliverOverlapAbsorber(
              handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
              sliver: SliverPersistentHeader(
                pinned: true,
                delegate: ProfileTabBarHeader(tabBar),
              ),
            ),
          ],
          body: TabBarView(children: [for (final tab in tabs) body(tab)]),
        ),
      ),
    );
  }

  List<Widget> _summary(BuildContext context, List<Entity> players) {
    final active = matches.where((m) => m.isProfileUpcoming).take(2);
    final finished = matches.where((m) => m.isFinished).toList();
    final main = competitions.firstOrNull;
    return [
      const ProfileSectionTitle('Partidos destacados'),
      if (active.isEmpty)
        const InlineEmpty(Icons.event_outlined, 'Sin partidos próximos')
      else
        for (final match in active) MatchCard(match, data),
      if (finished.isNotEmpty) ...[
        const ProfileSectionTitle('Último resultado'),
        MatchCard(finished.last, data),
      ],
      const ProfileSectionTitle('Competiciones'),
      if (competitions.isEmpty)
        const InlineEmpty(Icons.emoji_events_outlined, 'Sin competiciones')
      else
        for (final competition in competitions.take(3))
          EntityTile(competition, 'competition'),
      const ProfileSectionTitle('Información'),
      ProfileInfoCard([
        if (team.country.isNotEmpty) (Icons.public, 'País', team.country),
        if (main != null)
          (Icons.emoji_events_outlined, 'Competición principal', main.name),
        if (players.isNotEmpty)
          (Icons.groups_outlined, 'Jugadores', '${players.length}'),
      ]),
    ];
  }
}

const _weekdays = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
const _months = [
  'ene',
  'feb',
  'mar',
  'abr',
  'may',
  'jun',
  'jul',
  'ago',
  'sep',
  'oct',
  'nov',
  'dic',
];

String matchDayLabel(DateTime date) =>
    '${_weekdays[date.weekday - 1]} ${date.day} ${_months[date.month - 1]}';

class TeamHeader extends StatelessWidget {
  const TeamHeader({
    required this.team,
    required this.competition,
    required this.players,
    super.key,
  });

  final Entity team;
  final Entity? competition;
  final int players;

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [profileHeaderTop, profileHeaderBottom],
      ),
    ),
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 84,
          height: 84,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .06),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: profileCardBorder),
          ),
          child: EntityAvatar(team, size: 64),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                team.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 22,
                  height: 1.15,
                  fontWeight: FontWeight.w900,
                ),
              ),
              if (team.country.isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.public, size: 14, color: muted),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        team.country,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: muted, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (competition != null)
                    ProfileHeaderChip(
                      icon: Icons.emoji_events_outlined,
                      label: competition!.name,
                      onTap: () =>
                          context.push('/competition/${competition!.id}'),
                    ),
                  if (players > 0)
                    ProfileHeaderChip(
                      icon: Icons.groups_outlined,
                      label: '$players jugadores',
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

class TeamSquad extends StatelessWidget {
  const TeamSquad(this.players, {this.demo = false, this.state, super.key});

  final List<Entity> players;
  final bool demo;

  /// Server squad state (see [Snapshot.squadState]).
  final String? state;

  @override
  Widget build(BuildContext context) {
    if (players.isEmpty) {
      // Only a confirmed absence says "no disponible"; anything else (never
      // fetched, in flight, retrying, unknown) is still pending.
      return state == 'CONFIRMED_EMPTY'
          ? const InlineEmpty(Icons.groups_outlined, 'Plantilla no disponible')
          : const InlineEmpty(
              Icons.hourglass_empty_rounded,
              'Plantilla pendiente',
              key: ValueKey('squad-pending'),
            );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 8, 2, 0),
          child: Text(
            demo
                ? 'Selección de jugadores de demostración'
                : '${players.length} jugadores',
            style: const TextStyle(color: muted, fontSize: 12),
          ),
        ),
        for (final (label, group) in squadGroups(players)) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 14, 2, 8),
            child: Row(
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${group.length}',
                  style: const TextStyle(color: muted, fontSize: 13),
                ),
              ],
            ),
          ),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < group.length; i++) ...[
                  if (i > 0)
                    const Divider(
                      height: 1,
                      indent: 64,
                      color: profileCardBorder,
                    ),
                  SquadPlayerRow(group[i], group: label),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class SquadPlayerRow extends StatelessWidget {
  const SquadPlayerRow(this.player, {required this.group, super.key});

  final Entity player;
  final String group;

  @override
  Widget build(BuildContext context) {
    final number = _shirtNumber(player);
    final nationality =
        (player.json['nationality']?.toString().trim().isNotEmpty == true
                ? player.json['nationality'].toString()
                : player.country)
            .trim();
    final position =
        _groupSingular[group] ??
        playerPositionLabel(player.json['position']?.toString() ?? '');
    final subtitle = [
      if (position.isNotEmpty) position,
      if (nationality.isNotEmpty) nationality,
    ].join(' · ');
    return InkWell(
      onTap: () => context.push('/player/${player.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                number?.toString() ?? '–',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: muted,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: 8),
            PlayerPhoto(player, size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    player.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
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

/// Canonical verified photo only; initials stay underneath while loading or
/// on failure, so there is no spinner and never a broken image.
class PlayerPhoto extends StatelessWidget {
  const PlayerPhoto(this.player, {required this.size, super.key});

  final Entity player;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2A3B36), Color(0xFF1A2622)],
        ),
        border: Border.all(color: lime.withValues(alpha: .35)),
      ),
      child: Text(
        player.initials,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * .32,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
    final image = player.imageUrl;
    if (image == null) return fallback;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          fallback,
          ClipOval(
            child: Image.network(
              image,
              width: size,
              height: size,
              cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                  .round(),
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              errorBuilder: (_, error, stack) => const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }
}

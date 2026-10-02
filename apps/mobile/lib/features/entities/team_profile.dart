import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models.dart';
import '../../core/profile_context.dart';
import '../../core/entity_media.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';
import 'profile_context_bar.dart';
import 'profile_widgets.dart';
import 'standings.dart';
import 'team_matches_tab.dart';
import 'team_summary.dart';

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

int? _shirtNumber(Entity player) => player.shirtNumber;

/// Age in whole years from `age` or `dateOfBirth` (null when unknown).
int? playerAge(Entity player, {DateTime? now}) {
  final value = player.json['age'];
  final born = DateTime.tryParse(player.json['dateOfBirth']?.toString() ?? '');
  if (born != null) {
    final today = now ?? DateTime.now();
    var years = today.year - born.year;
    if (today.month < born.month ||
        (today.month == born.month && today.day < born.day)) {
      years--;
    }
    // An implausible birth date falls back to the provider's age.
    if (years > 0 && years < 80) return years;
  }
  if (value is num && value > 0 && value < 80) return value.toInt();
  return null;
}

/// Players grouped by position, each group sorted by shirt number then name;
/// each canonical player once.
List<(String, List<Entity>)> squadGroups(Iterable<Entity> players) {
  final groups = <String, List<Entity>>{};
  final seen = <String>{};
  for (final player in players) {
    if (!seen.add(player.id)) continue;
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

/// The profile's table, chosen deterministically (never by list order):
///  1. the team's own main competition (`team.competitionId`) when its table
///     really contains the team (its own group only);
///  2. otherwise the only competition whose table contains the team;
///  3. several candidates and no main-competition signal: none (no "Tabla"
///     tab) rather than an arbitrary pick.
/// Match Center keeps its exact competition+season table; this is only for
/// team / national-team profiles.
String? teamTableCompetitionId(Snapshot data, Entity team) {
  bool shows(String id) =>
      standingsGroups(
        standingsTableFor(data, id),
        data,
        focusTeamIds: {team.id},
      )?.any((group) => group.rows.any((row) => row['teamId'] == team.id)) ==
      true;
  final main = team.json['competitionId']?.toString() ?? '';
  if (main.isNotEmpty && shows(main)) return main;
  final candidates = {
    for (final table in data.standings)
      if (table['competitionId'] case final String id when shows(id)) id,
  };
  return candidates.length == 1 ? candidates.single : null;
}

/// Name of the canonical competition an alias [competitionId] redirects to
/// (snapshot redirects first, then the session's), when that competition is
/// known; null when [competitionId] is not an alias or nothing better is
/// known.
String? canonicalCompetitionName(
  Snapshot data,
  EntityRedirectMemory redirects,
  String competitionId,
) {
  for (final resolved in {
    data.resolveEntityId(competitionId),
    redirects.resolve(competitionId),
  }) {
    if (resolved == competitionId) continue;
    final name = data.competition(resolved)?.name;
    if (name != null && name.isNotEmpty) return name;
  }
  return null;
}

class TeamProfileView extends ConsumerWidget {
  const TeamProfileView({
    required this.data,
    required this.team,
    required this.competitions,
    required this.matches,
    this.initialCompetitionId,
    this.initialSeason,
    this.loading = false,
    super.key,
  });

  final Snapshot data;
  final Entity team;
  final List<Entity> competitions;
  final List<FootballMatch> matches;

  /// [data] is only what the session already knew about the team (search,
  /// Explorar, calendar…) while the profile itself loads: the header and
  /// every independent section render now, and the sections that need the
  /// profile say they are loading instead of "empty".
  final bool loading;

  /// Context of the match the profile was opened from (#161), if any.
  final String? initialCompetitionId;
  final String? initialSeason;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final players = data.players
        .where((player) => player.json['teamId'] == team.id)
        .toList();
    // Competition + season context: the user's choice this session, else the
    // match it was opened from, else the server's default.
    final request = profileContextRequest(
      ref,
      team.id,
      initialCompetitionId: initialCompetitionId,
      initialSeason: initialSeason,
    );
    // Loading or failed: the last context shown (or the profile's own
    // snapshot) stays; the profile is never blocked.
    ref.listen(teamContextProvider(request), (_, next) {
      final value = next.asData?.value;
      if (value != null) {
        ref.read(lastTeamContextProvider.notifier).remember(value);
      }
    });
    final current = ref.watch(teamContextProvider(request));
    final teamContext =
        current.asData?.value ?? ref.watch(lastTeamContextProvider)[team.id];
    // The requested context failed: the last one stays, and says so.
    final switchFailed = current.hasError && teamContext != null;
    // An option sent under an alias competition id (e.g. the legacy
    // `fb_comp_cr`) shows its canonical competition's name.
    final redirects = ref.watch(entityMediaProvider).redirects;
    ProfileContextOption shown(ProfileContextOption option) {
      final canonical = canonicalCompetitionName(
        data,
        redirects,
        option.competitionId,
      );
      return canonical == null ? option : option.withCompetitionName(canonical);
    }

    final rawSelected = teamContext?.selected;
    final selected = rawSelected == null ? null : shown(rawSelected);
    final tableId = teamTableCompetitionId(data, team);
    // The selected season's exact table; for the competition's current
    // season the profile's own cached table is the same table.
    final cachedCurrent =
        selected != null &&
        selected.currentSeason &&
        tableId == selected.competitionId &&
        normalizeSeasonKey(
              standingsTableFor(data, tableId!)?['season']?.toString(),
            ) ==
            selected.seasonKey;
    final contextTable = selected != null;
    // The table the summary shows: the selected context's exact table, or
    // (no context) the profile's own table choice.
    final summaryTable = selected != null
        ? (teamContext!.standings.isNotEmpty
              ? (
                  snapshot: teamContext.tableSnapshot(data),
                  competitionId: selected.competitionId,
                  label: selected.label,
                )
              : cachedCurrent
              ? (snapshot: data, competitionId: tableId, label: selected.label)
              : null)
        : tableId == null
        ? null
        : (
            snapshot: data,
            competitionId: tableId,
            label: data.competition(tableId)?.name ?? 'Tabla',
          );
    final tabs = [
      'Resumen',
      'Partidos',
      if (contextTable || tableId != null) 'Tabla',
      'Plantilla',
      'Noticias',
      'Transferencias',
    ];
    final tabBar = profileTabBar(tabs);

    Widget body(String tab) => switch (tab) {
      'Resumen' => ProfileTabList('resumen', [
        if (data.demo) const DemoNotice(),
        if (loading)
          const ProfileLoadingNotice(
            'Cargando datos del equipo…',
            key: ValueKey('team-profile-loading'),
          ),
        Builder(
          builder: (tabContext) => TeamSummary(
            data: data,
            team: team,
            matches: matches,
            competitions: competitions,
            players: players.length,
            table: summaryTable?.snapshot,
            tableCompetitionId: summaryTable?.competitionId,
            tableLabel: summaryTable?.label,
            onOpenTab: (tab) {
              final index = tabs.indexOf(tab);
              if (index >= 0) {
                DefaultTabController.of(tabContext).animateTo(index);
              }
            },
          ),
        ),
      ]),
      'Partidos' => TeamMatchesTab(
        team: team,
        data: data,
        matches: matches,
        contextOption: selected,
      ),
      'Tabla' => ProfileTabList('tabla', [
        if (data.demo) const DemoNotice(),
        if (contextTable)
          if (teamContext!.standings.isEmpty && cachedCurrent)
            Standings(data, tableId, focusTeamIds: {team.id})
          else if (teamContext.standings.isEmpty)
            const InlineEmpty(
              Icons.table_rows_outlined,
              'Tabla no disponible',
              key: ValueKey('profile-context-no-table'),
            )
          else
            Standings(
              teamContext.tableSnapshot(data),
              selected.competitionId,
              focusTeamIds: {team.id},
            )
        else
          Standings(data, tableId!, focusTeamIds: {team.id}),
      ]),
      'Plantilla' => ProfileTabList('plantilla', [
        if (data.demo) const DemoNotice(),
        if (loading)
          const ProfileLoadingNotice(
            'Cargando plantilla…',
            key: ValueKey('squad-loading'),
          )
        else
          TeamSquad(
            players,
            demo: data.demo,
            state: data.squadState,
            updatedAt: DateTime.tryParse(
              ((data.coverage?['squad'] as Map?)?['updatedAt'])?.toString() ??
                  '',
            ),
          ),
      ]),
      'Noticias' => ProfileTabList('noticias', [
        if (data.demo) const DemoNotice(),
        if (loading)
          const ProfileLoadingNotice(
            'Cargando noticias…',
            key: ValueKey('news-loading'),
          )
        else if (data.news.isEmpty)
          const InlineEmpty(Icons.article_outlined, 'Sin noticias disponibles')
        else
          for (final article in data.news) NewsArticleCard(article),
      ]),
      _ => ProfileTabList('transferencias', [
        if (data.demo) const DemoNotice(),
        if (loading)
          const ProfileLoadingNotice(
            'Cargando transferencias…',
            key: ValueKey('transfers-loading'),
          )
        else if (data.transfers.isEmpty)
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
          title: Text(
            team.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
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
            if (teamContext != null && selected != null)
              SliverToBoxAdapter(
                child: ProfileContextBar(
                  options: [for (final o in teamContext.options) shown(o)],
                  selected: selected,
                  failed: switchFailed,
                  onRetry: () => ref.invalidate(teamContextProvider(request)),
                  onSelect: (option) => ref
                      .read(profileContextSelectionProvider.notifier)
                      .select(team.id, option),
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
                team.displayName,
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
  const TeamSquad(
    this.players, {
    this.demo = false,
    this.state,
    this.updatedAt,
    super.key,
  });

  final List<Entity> players;
  final bool demo;

  /// Server squad state (see [Snapshot.squadState]).
  final String? state;

  /// When the stored squad was last confirmed (shown only while STALE).
  final DateTime? updatedAt;

  @override
  Widget build(BuildContext context) {
    if (players.isEmpty) {
      // "No disponible" only for a confirmed empty answer or no source at
      // all (distinct states, same copy); anything else (never fetched, in
      // flight, retrying, unknown) is still pending.
      return state == 'CONFIRMED_EMPTY' || state == 'UNAVAILABLE'
          ? const InlineEmpty(Icons.groups_outlined, 'Plantilla no disponible')
          : const InlineEmpty(
              Icons.hourglass_empty_rounded,
              'Plantilla pendiente',
              key: ValueKey('squad-pending'),
            );
    }
    final groups = squadGroups(players);
    final count = groups.fold<int>(0, (sum, g) => sum + g.$2.length);
    // No player classified by position: a lone "Otros" header says nothing,
    // so the squad is one plain list (still number-then-name order).
    final plain = groups.length == 1 && groups.single.$1 == 'Otros';
    final stale = state == 'STALE';
    // Costa Rica day, like the rest of the profile; a future date (clock
    // skew) is never shown.
    final now = costaRicaNow();
    final raw = updatedAt;
    final since = raw == null ? null : costaRicaTime(raw.toUtc());
    final sinceShown = since != null && !since.isAfter(now) ? since : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 8, 2, 0),
          child: Text(
            [
              demo
                  ? 'Selección de jugadores de demostración'
                  : count == 1
                  ? '1 jugador'
                  : '$count jugadores',
              // Stored squad older than its freshness window: say since when.
              if (stale && sinceShown != null)
                'Actualizada el ${sinceShown.day} ${_months[sinceShown.month - 1]}'
                    '${sinceShown.year == now.year ? '' : ' ${sinceShown.year}'}'
              else if (stale)
                'Pendiente de actualizar',
            ].join(' · '),
            key: const ValueKey('squad-summary'),
            style: const TextStyle(color: muted, fontSize: 12),
          ),
        ),
        for (final (label, group) in groups) ...[
          if (plain)
            const SizedBox(height: 12)
          else
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
    final age = playerAge(player);
    final subtitle = [
      if (position.isNotEmpty) position,
      if (age != null) '$age años',
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

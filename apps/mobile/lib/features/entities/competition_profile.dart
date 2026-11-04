import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';
import 'profile_widgets.dart';
import 'standings.dart';
import 'team_profile.dart' show matchDayLabel;

const double _competitionHeaderLogoSize = 74;
const double _competitionMatchTeamLogoSize = 26;
const double _competitionTeamGridLogoSize = 44;
const double _competitionStandingsTeamLogoSize = 26;

class CompetitionProfileView extends StatelessWidget {
  const CompetitionProfileView({
    required this.data,
    required this.competition,
    required this.matches,
    required this.teams,
    super.key,
  });

  final Snapshot data;
  final Entity competition;
  final List<FootballMatch> matches;
  final List<Entity> teams;

  @override
  Widget build(BuildContext context) {
    final table = standingsTableFor(data, competition.id);
    final groups = standingsGroups(table, data);
    final hasTable = groups != null && groups.isNotEmpty;
    final upcoming = matches
        .where((match) => match.isUpcoming)
        .take(5)
        .toList();
    final results = matches
        .where((match) => match.isFinished)
        .toList()
        .reversed
        .take(5)
        .toList();
    final tabs = [
      'Resumen',
      'Partidos',
      if (hasTable) 'Tabla',
      'Equipos',
      'Noticias',
    ];

    Widget body(String tab) => switch (tab) {
      'Resumen' => ProfileTabList('resumen', [
        if (data.demo) const DemoNotice(),
        if (upcoming.isNotEmpty) ...[
          const ProfileSectionTitle('Próximos partidos'),
          CompetitionMatchList(matches: upcoming.take(3).toList(), data: data),
        ],
        if (results.isNotEmpty) ...[
          const ProfileSectionTitle('Últimos resultados'),
          CompetitionMatchList(matches: results.take(3).toList(), data: data),
        ],
        if (hasTable) ...[
          const ProfileSectionTitle('Clasificación'),
          _CompetitionGroupsSummary(groups: groups),
        ],
        if (teams.isNotEmpty) ...[
          const ProfileSectionTitle('Equipos participantes'),
          CompetitionTeamsGrid(teams.take(8).toList()),
        ],
        if (upcoming.isEmpty && results.isEmpty && !hasTable && teams.isEmpty)
          const InlineEmpty(
            Icons.info_outline,
            'Información todavía no disponible',
          ),
      ]),
      'Partidos' => ProfileTabList('partidos', [
        if (data.demo) const DemoNotice(),
        if (upcoming.isNotEmpty) ...[
          const ProfileSectionTitle('Próximos'),
          CompetitionMatchList(matches: upcoming, data: data),
        ],
        if (results.isNotEmpty) ...[
          const ProfileSectionTitle('Resultados'),
          CompetitionMatchList(matches: results, data: data),
        ],
        if (upcoming.isEmpty && results.isEmpty)
          const InlineEmpty(
            Icons.event_busy_outlined,
            'Sin partidos disponibles',
          ),
      ]),
      'Tabla' => ProfileTabList('tabla', [
        if (data.demo) const DemoNotice(),
        Standings(
          data,
          competition.id,
          teamAvatarSize: _competitionStandingsTeamLogoSize,
        ),
      ]),
      'Equipos' => ProfileTabList('equipos', [
        if (data.demo) const DemoNotice(),
        if (teams.isEmpty)
          const InlineEmpty(Icons.shield_outlined, 'Sin equipos disponibles')
        else
          CompetitionTeamsGrid(teams),
      ]),
      _ => ProfileTabList('noticias', [
        if (data.demo) const DemoNotice(),
        if (data.news.isEmpty)
          const InlineEmpty(Icons.article_outlined, 'Sin noticias disponibles')
        else
          for (final article in data.news) NewsArticleCard(article),
      ]),
    };

    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            competition.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          backgroundColor: profileHeaderTop,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          actions: [FollowButton('competition', competition.id)],
        ),
        body: NestedScrollView(
          headerSliverBuilder: (context, _) => [
            SliverToBoxAdapter(
              child: CompetitionHeader(competition: competition),
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
}

class CompetitionHeader extends StatelessWidget {
  const CompetitionHeader({required this.competition, super.key});

  final Entity competition;

  @override
  Widget build(BuildContext context) {
    final season = competition.json['season']?.toString().trim() ?? '';
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
          Container(
            width: 84,
            height: 84,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .06),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: profileCardBorder),
            ),
            child: SizedBox(
              key: const ValueKey('competition-profile-logo'),
              child: EntityAvatar(
                competition,
                size: _competitionHeaderLogoSize,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  competition.displayName,
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
                    if (competition.country.isNotEmpty)
                      ProfileHeaderChip(
                        icon: Icons.public,
                        label: competition.country,
                      ),
                    if (season.isNotEmpty)
                      ProfileHeaderChip(
                        icon: Icons.calendar_month_outlined,
                        label: season,
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

class CompetitionMatchList extends StatelessWidget {
  const CompetitionMatchList({
    required this.matches,
    required this.data,
    super.key,
  });

  final List<FootballMatch> matches;
  final Snapshot data;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: [
        for (final (index, match) in matches.indexed) ...[
          if (index > 0) const Divider(height: 1),
          CompetitionMatchRow(match: match, data: data),
        ],
      ],
    ),
  );
}

class CompetitionMatchRow extends StatelessWidget {
  const CompetitionMatchRow({
    required this.match,
    required this.data,
    super.key,
  });

  final FootballMatch match;
  final Snapshot data;

  @override
  Widget build(BuildContext context) {
    final home = data.team(match.homeId);
    final away = data.team(match.awayId);
    if (home == null || away == null) return const SizedBox.shrink();
    final phase =
        [
              match.json['stage']?.toString().trim(),
              match.json['group']?.toString().trim(),
              match.json['round']?.toString().trim(),
            ]
            .whereType<String>()
            .where((value) => value.isNotEmpty)
            .toSet()
            .join(' · ');
    final center = match.showKickoff
        ? localTime(context, match.startTime)
        : match.score;
    return Semantics(
      button: true,
      label: [
        matchDayLabel(match.startTime),
        home.displayName,
        center,
        away.displayName,
        if (phase.isNotEmpty) phase,
      ].join(', '),
      excludeSemantics: true,
      onTap: () =>
          context.push('/match/${match.id}', extra: data.forMatch(match.id)),
      child: InkWell(
        key: ValueKey('competition-match-${match.id}'),
        onTap: () =>
            context.push('/match/${match.id}', extra: data.forMatch(match.id)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                [
                  matchDayLabel(match.startTime),
                  if (phase.isNotEmpty) phase,
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: muted, fontSize: 11),
              ),
              const SizedBox(height: 7),
              Row(
                children: [
                  Expanded(
                    child: _CompetitionMatchTeam(
                      home,
                      avatarKey: ValueKey(
                        'competition-match-${match.id}-home-logo',
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 68,
                    child: Text(
                      center,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                  Expanded(
                    child: _CompetitionMatchTeam(
                      away,
                      trailing: true,
                      avatarKey: ValueKey(
                        'competition-match-${match.id}-away-logo',
                      ),
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
}

class _CompetitionMatchTeam extends StatelessWidget {
  const _CompetitionMatchTeam(
    this.team, {
    required this.avatarKey,
    this.trailing = false,
  });
  final Entity team;
  final Key avatarKey;
  final bool trailing;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: trailing
        ? MainAxisAlignment.end
        : MainAxisAlignment.start,
    children: [
      if (!trailing) ...[
        SizedBox(
          key: avatarKey,
          child: EntityAvatar(team, size: _competitionMatchTeamLogoSize),
        ),
        const SizedBox(width: 6),
      ],
      Flexible(
        child: Text(
          team.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: trailing ? TextAlign.end : TextAlign.start,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
      ),
      if (trailing) ...[
        const SizedBox(width: 6),
        SizedBox(
          key: avatarKey,
          child: EntityAvatar(team, size: _competitionMatchTeamLogoSize),
        ),
      ],
    ],
  );
}

class CompetitionTeamsGrid extends StatelessWidget {
  const CompetitionTeamsGrid(this.teams, {super.key});
  final List<Entity> teams;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth < 340 ? 2 : 3;
      const gap = 8.0;
      final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final team in teams)
            SizedBox(
              width: width,
              child: InkWell(
                key: ValueKey('competition-team-${team.id}'),
                borderRadius: BorderRadius.circular(14),
                onTap: () => context.push('/team/${team.id}'),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 108),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .03),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: profileCardBorder),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        key: ValueKey('competition-team-${team.id}-logo'),
                        child: EntityAvatar(
                          team,
                          size: _competitionTeamGridLogoSize,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        team.displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (team.country.isNotEmpty)
                        Text(
                          team.country,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: muted, fontSize: 10),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

class _CompetitionGroupsSummary extends StatelessWidget {
  const _CompetitionGroupsSummary({required this.groups});
  final List<StandingsGroup> groups;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Column(
        children: [
          for (final (index, group) in groups.indexed) ...[
            if (index > 0) const Divider(height: 1),
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.table_rows_outlined, color: lime),
              title: Text(group.label ?? 'Tabla general'),
              trailing: Text(
                '${group.rows.length} equipos',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

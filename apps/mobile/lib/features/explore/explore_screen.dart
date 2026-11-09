import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models.dart';
import '../../core/interests.dart';
import '../../core/providers.dart';
import '../../core/relevance.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';

class ExploreScreen extends ConsumerStatefulWidget {
  const ExploreScreen({super.key, this.focusType});

  final String? focusType;

  @override
  ConsumerState<ExploreScreen> createState() => _ExploreScreenState();
}

const remoteSearchRetryDelays = [
  Duration(seconds: 3),
  Duration(seconds: 5),
  Duration(seconds: 8),
];

typedef _SearchRequest = ({String query, String? country});

class _ExploreScreenState extends ConsumerState<ExploreScreen> {
  final searchController = TextEditingController();
  final searchFocus = FocusNode();
  final previousSearches = <_SearchRequest, Snapshot>{};
  String requestQuery = '';
  String pendingQuery = '';
  Timer? debounce;
  Timer? remoteRetry;
  _SearchRequest? remoteRetryRequest;
  _SearchRequest? lastRetryRequest;
  int remoteAttempts = 0;
  Snapshot? previousDiscovery;
  bool typing = false;

  @override
  void dispose() {
    debounce?.cancel();
    remoteRetry?.cancel();
    searchController.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  void _resetRemoteSearch() {
    remoteRetry?.cancel();
    remoteRetry = null;
    remoteRetryRequest = null;
    lastRetryRequest = null;
    remoteAttempts = 0;
  }

  void _scheduleRemoteRetry(_SearchRequest request) {
    final currentCountry = ref
        .read(preferenceProvider)
        .asData
        ?.value
        .effectiveCountry;
    if (!mounted ||
        request.query != requestQuery ||
        request.country != currentCountry) {
      return;
    }
    if (lastRetryRequest != request) {
      _resetRemoteSearch();
      lastRetryRequest = request;
    }
    if (remoteRetry != null && remoteRetryRequest != request) {
      remoteRetry?.cancel();
      remoteRetry = null;
      remoteAttempts = 0;
    }
    if (remoteRetry != null ||
        remoteAttempts >= remoteSearchRetryDelays.length) {
      return;
    }
    remoteRetryRequest = request;
    remoteRetry = Timer(remoteSearchRetryDelays[remoteAttempts], () {
      final latestCountry = mounted
          ? ref.read(preferenceProvider).asData?.value.effectiveCountry
          : null;
      if (!mounted ||
          request.query != requestQuery ||
          request.country != latestCountry) {
        _resetRemoteSearch();
        return;
      }
      setState(() {
        remoteAttempts++;
        remoteRetry = null;
        remoteRetryRequest = null;
      });
      ref.invalidate(searchSnapshotProvider(request));
    });
  }

  void _onQueryChanged(String value) {
    final trimmed = value.trim();
    final next = trimmed.length >= 2 ? trimmed : '';
    pendingQuery = next;
    debounce?.cancel();
    _resetRemoteSearch();
    if (next.isEmpty) {
      // Even a one-character query needs to update the clear button, without
      // starting a remote search before the two-character threshold.
      setState(() {
        requestQuery = '';
        typing = false;
      });
      return;
    }
    if (next == requestQuery) {
      if (typing) setState(() => typing = false);
      return;
    }
    setState(() {
      // Stop watching the obsolete query now, not after the debounce. The
      // auto-dispose provider detaches/cancels only this screen's waiter.
      requestQuery = '';
      typing = true;
    });
    debounce = Timer(const Duration(milliseconds: 275), () {
      if (!mounted || pendingQuery == requestQuery) return;
      setState(() {
        requestQuery = pendingQuery;
        typing = false;
      });
    });
  }

  void _clearQuery() {
    searchController.clear();
    _onQueryChanged('');
    searchFocus.requestFocus();
  }

  void _retry(bool hasQuery, _SearchRequest request) {
    if (hasQuery) {
      _resetRemoteSearch();
      ref.invalidate(searchSnapshotProvider(request));
    } else {
      ref.invalidate(exploreSnapshotProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasRemoteQuery = requestQuery.isNotEmpty;
    final hasQuery = typing || hasRemoteQuery;
    final visibleQuery = typing ? pendingQuery : requestQuery;
    final country = ref
        .watch(preferenceProvider)
        .asData
        ?.value
        .effectiveCountry;
    final request = (query: requestQuery, country: country);
    if (hasRemoteQuery) {
      ref.listen(searchSnapshotProvider(request), (_, next) {
        if (!next.isLoading && next.asData?.value.pendingRemote == true) {
          _scheduleRemoteRetry(request);
        }
      });
    }
    final result = hasRemoteQuery
        ? ref.watch(searchSnapshotProvider(request))
        : ref.watch(exploreSnapshotProvider);
    final fresh = result.asData?.value;
    if (fresh != null) {
      if (hasRemoteQuery) {
        previousSearches[request] = fresh;
      } else {
        previousDiscovery = fresh;
      }
    }
    final source =
        fresh ??
        (hasRemoteQuery ? previousSearches[request] : null) ??
        previousDiscovery;
    final localResults = hasQuery && (!hasRemoteQuery || fresh == null);
    final data = source == null ? null : presentSnapshotForSession(ref, source);
    final refreshing =
        typing ||
        result.isLoading ||
        (!hasQuery && fresh?.revalidating == true);
    final failed = result.hasError || (!hasQuery && fresh?.stale == true);
    final searchingRemote =
        hasQuery &&
        data?.pendingRemote == true &&
        remoteAttempts < remoteSearchRetryDelays.length;
    final focus =
        const {'team', 'competition', 'player'}.contains(widget.focusType)
        ? widget.focusType
        : null;
    final competitions = focus == null || focus == 'competition'
        ? _matching(data?.competitions, data, visibleQuery, local: localResults)
        : const <Entity>[];
    final teams = focus == null || focus == 'team'
        ? _matching(data?.teams, data, visibleQuery, local: localResults)
        : const <Entity>[];
    final follows =
        ref.watch(followsProvider).asData?.value ?? const <String>{};
    final players = focus != null && focus != 'player'
        ? const <Entity>[]
        : hasQuery
        ? _matching(data?.players, data, visibleQuery, local: localResults)
        : suggestAvailablePlayers(
            remote:
                ref
                    .watch(playerSuggestionsProvider(followedTeamsKey(follows)))
                    .asData
                    ?.value ??
                const <Entity>[],
            loaded: data?.players ?? const <Entity>[],
            follows: follows,
            country: country,
          );
    final favoriteTeams = hasQuery
        ? const <Entity>[]
        : teams.where((team) => follows.contains('team:${team.id}')).toList();
    final suggestedTeams = favoriteTeams.isEmpty
        ? teams
        : teams.where((team) => !follows.contains('team:${team.id}')).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Explorar',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Semantics(
              textField: true,
              label: 'Buscar en FutBeat',
              child: TextField(
                key: const ValueKey('explore-search-field'),
                controller: searchController,
                focusNode: searchFocus,
                autofocus: false,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: switch (focus) {
                    'team' => 'Buscar equipos...',
                    'competition' => 'Buscar competiciones...',
                    'player' => 'Buscar jugadores...',
                    _ => 'Buscar equipos, jugadores, ligas...',
                  },
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: searchController.text.isEmpty
                      ? null
                      : IconButton(
                          key: const ValueKey('explore-clear-search'),
                          tooltip: 'Limpiar búsqueda',
                          onPressed: _clearQuery,
                          icon: const Icon(Icons.close),
                        ),
                ),
                onChanged: _onQueryChanged,
              ),
            ),
          ),
          if (typing || (refreshing && data != null))
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _ExploreContent(
              data: data,
              hasQuery: hasQuery,
              query: visibleQuery,
              focusType: focus,
              refreshing: refreshing,
              failed: failed,
              searchingRemote: searchingRemote,
              remoteExhausted:
                  hasQuery && data?.pendingRemote == true && !searchingRemote,
              competitions: competitions,
              favoriteTeams: favoriteTeams,
              teams: suggestedTeams,
              players: players,
              onRetry: () => _retry(hasQuery, request),
            ),
          ),
        ],
      ),
    );
  }
}

List<Entity> _matching(
  List<Entity>? entities,
  Snapshot? data,
  String query, {
  bool local = false,
}) {
  if (entities == null) return const <Entity>[];
  final seen = <String>{};
  return [
    for (final entity in entities)
      if (((!local && data?.demo != true) || entity.matches(query)) &&
          seen.add(entity.id))
        entity,
  ];
}

/// Reuses canonical catalogue rows already on screen. Remote suggestions may
/// be sparse or unavailable offline; neither case creates another request.
/// IDs, never names, decide whether two rows represent the same player.
List<Entity> suggestAvailablePlayers({
  required List<Entity> remote,
  required List<Entity> loaded,
  required Set<String> follows,
  String? country,
}) {
  final byId = <String, Entity>{};
  for (final player in [...remote, ...loaded]) {
    byId.putIfAbsent(player.id, () => player);
  }
  int rank(Entity player) {
    if (follows.contains('player:${player.id}')) return 0;
    final teamId =
        player.json['teamId']?.toString() ?? player.json['clubId']?.toString();
    if (teamId != null && follows.contains('team:$teamId')) return 1;
    if (entityMatchesCountry(player, country)) return 2;
    return 3;
  }

  final values = byId.values.toList(growable: false);
  values.sort((a, b) {
    final priority = rank(a).compareTo(rank(b));
    return priority != 0 ? priority : a.id.compareTo(b.id);
  });
  return values.take(12).toList(growable: false);
}

class _ExploreContent extends StatelessWidget {
  const _ExploreContent({
    required this.data,
    required this.hasQuery,
    required this.query,
    required this.focusType,
    required this.refreshing,
    required this.failed,
    required this.searchingRemote,
    required this.remoteExhausted,
    required this.competitions,
    required this.favoriteTeams,
    required this.teams,
    required this.players,
    required this.onRetry,
  });

  final Snapshot? data;
  final bool hasQuery;
  final String query;
  final String? focusType;
  final bool refreshing;
  final bool failed;
  final bool searchingRemote;
  final bool remoteExhausted;
  final List<Entity> competitions;
  final List<Entity> favoriteTeams;
  final List<Entity> teams;
  final List<Entity> players;
  final VoidCallback onRetry;

  bool get isEmpty =>
      competitions.isEmpty &&
      favoriteTeams.isEmpty &&
      teams.isEmpty &&
      players.isEmpty;

  @override
  Widget build(BuildContext context) {
    if (refreshing && (data == null || (hasQuery && isEmpty))) {
      return _ColdLoading(hasQuery: hasQuery, query: query);
    }
    if (data == null && failed) return _LoadError(onRetry: onRetry);

    return CustomScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        const SliverPadding(padding: EdgeInsets.only(top: 8)),
        if (data?.demo == true)
          const _BoxSliver(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: DemoNotice(),
          ),
        _BoxSliver(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
          child: _ModeHeader(
            hasQuery: hasQuery,
            query: query,
            focusType: focusType,
          ),
        ),
        if (failed)
          _BoxSliver(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 4),
            child: _InlineError(onRetry: onRetry),
          ),
        if (searchingRemote)
          const _BoxSliver(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: _RemoteSearchNotice(),
          ),
        if (remoteExhausted && !refreshing && !failed)
          _BoxSliver(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextButton(
              onPressed: onRetry,
              child: const Text('Reintentar búsqueda'),
            ),
          ),
        if (!searchingRemote &&
            !remoteExhausted &&
            !refreshing &&
            !failed &&
            isEmpty)
          _BoxSliver(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: EmptyState(
              hasQuery
                  ? 'No encontramos resultados para “$query”.'
                  : 'Sin sugerencias disponibles',
              !hasQuery
                  ? 'Vuelve a intentarlo más tarde.'
                  : 'Prueba con otro nombre o abreviación.',
              icon: hasQuery ? Icons.search_off : Icons.explore_outlined,
            ),
          ),
        if (favoriteTeams.isNotEmpty)
          _EntitySection(
            title: 'Mis equipos',
            entities: favoriteTeams,
            type: 'team',
            data: data!,
          ),
        if (competitions.isNotEmpty)
          _EntitySection(
            title: 'Competiciones',
            entities: competitions,
            type: 'competition',
            data: data!,
          ),
        if (teams.isNotEmpty)
          _EntitySection(
            title: hasQuery ? 'Equipos' : 'Equipos sugeridos',
            entities: teams,
            type: 'team',
            data: data!,
          ),
        if (players.isNotEmpty)
          _EntitySection(
            title: hasQuery ? 'Jugadores' : 'Jugadores sugeridos',
            entities: players,
            type: 'player',
            data: data!,
          ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
      ],
    );
  }
}

class _ModeHeader extends StatelessWidget {
  const _ModeHeader({
    required this.hasQuery,
    required this.query,
    required this.focusType,
  });

  final bool hasQuery;
  final String query;
  final String? focusType;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        hasQuery
            ? 'Resultados para “$query”'
            : switch (focusType) {
                'team' => 'Encuentra equipos',
                'competition' => 'Encuentra competiciones',
                'player' => 'Encuentra jugadores',
                _ => 'Descubre FutBeat',
              },
        key: ValueKey(
          hasQuery ? 'explore-results-title' : 'explore-discover-title',
        ),
        style: Theme.of(context).textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 4),
      Text(
        hasQuery
            ? switch (focusType) {
                'team' => 'Equipos que coinciden.',
                'competition' => 'Competiciones que coinciden.',
                'player' => 'Jugadores que coinciden.',
                _ => 'Equipos, jugadores y competiciones que coinciden.',
              }
            : 'Sugerencias reales según tu país y tus intereses.',
        style: const TextStyle(color: muted, height: 1.35),
      ),
    ],
  );
}

class _EntitySection extends StatelessWidget {
  const _EntitySection({
    required this.title,
    required this.entities,
    required this.type,
    required this.data,
  });

  final String title;
  final List<Entity> entities;
  final String type;
  final Snapshot data;

  @override
  Widget build(BuildContext context) => SliverMainAxisGroup(
    slivers: [
      _BoxSliver(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        child: heading(context, title),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => _ExploreEntityTile(
              entity: entities[index],
              type: type,
              data: data,
            ),
            childCount: entities.length,
          ),
        ),
      ),
    ],
  );
}

class _ExploreEntityTile extends StatelessWidget {
  const _ExploreEntityTile({
    required this.entity,
    required this.type,
    required this.data,
  });

  final Entity entity;
  final String type;
  final Snapshot data;

  String get subtitle {
    final parts = <String>[];
    if (type == 'player') {
      final club = _firstText(entity.json, const [
        'teamName',
        'clubName',
        'currentTeamName',
      ]);
      final teamId = _firstText(entity.json, const ['teamId', 'clubId']);
      final team = teamId == null ? null : data.team(teamId)?.displayName;
      final position = playerPositionLabel(
        entity.json['position']?.toString() ?? '',
      );
      final nationality =
          _firstText(entity.json, const ['nationality']) ?? entity.country;
      if ((club ?? team)?.isNotEmpty == true) parts.add(club ?? team!);
      if (position.isNotEmpty) parts.add(position);
      if (nationality.isNotEmpty) parts.add(nationality);
    } else if (type == 'team') {
      final country = entityCountryLabel(entity);
      final competitionId = entity.json['competitionId']?.toString();
      final competition = competitionId == null
          ? null
          : data.competition(competitionId)?.displayName;
      if (country?.isNotEmpty == true) parts.add(country!);
      if (competition?.isNotEmpty == true) parts.add(competition!);
    } else {
      final country = entityCountryLabel(entity);
      if (country?.isNotEmpty == true) parts.add(country!);
      final region = _firstText(entity.json, const ['region']);
      if (region != null && region != country) parts.add(region);
    }
    return parts.toSet().join(' · ');
  }

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      minVerticalPadding: 10,
      leading: EntityAvatar(entity),
      title: Text(
        entity.displayName,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: muted),
            ),
      trailing: FollowButton(
        type,
        entity.id,
        label: entity.displayName,
        compact: true,
      ),
      onTap: () => context.push('/$type/${entity.id}'),
    ),
  );
}

String? _firstText(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key]?.toString().trim();
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

class _ColdLoading extends StatelessWidget {
  const _ColdLoading({required this.hasQuery, required this.query});

  final bool hasQuery;
  final String query;

  @override
  Widget build(BuildContext context) {
    final message = hasQuery
        ? 'Buscando “$query”…'
        : 'Cargando recomendaciones…';
    return ContentSkeleton(label: message);
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const EmptyState(
            'No pudimos cargar los resultados.',
            'Intenta nuevamente.',
            icon: Icons.cloud_off_outlined,
          ),
          FilledButton(onPressed: onRetry, child: const Text('Reintentar')),
        ],
      ),
    ),
  );
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_outlined, color: muted),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'No pudimos actualizar. Conservamos los resultados disponibles.',
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Reintentar')),
        ],
      ),
    ),
  );
}

class _RemoteSearchNotice extends StatelessWidget {
  const _RemoteSearchNotice();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 10),
    child: Row(
      children: [
        SizedBox.square(
          dimension: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            'Buscando más jugadores…',
            style: TextStyle(color: muted),
          ),
        ),
      ],
    ),
  );
}

class _BoxSliver extends StatelessWidget {
  const _BoxSliver({required this.child, this.padding = EdgeInsets.zero});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: Padding(padding: padding, child: child),
  );
}

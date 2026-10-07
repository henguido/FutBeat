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
  const ExploreScreen({super.key});

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
      if (requestQuery.isEmpty && !typing) return;
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
    setState(() => typing = true);
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
      previousSearches.remove(request);
      ref.invalidate(searchSnapshotProvider(request));
    } else {
      ref.invalidate(exploreSnapshotProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasQuery = requestQuery.isNotEmpty;
    final country = ref
        .watch(preferenceProvider)
        .asData
        ?.value
        .effectiveCountry;
    final request = (query: requestQuery, country: country);
    if (hasQuery) {
      ref.listen(searchSnapshotProvider(request), (_, next) {
        if (!next.isLoading && next.asData?.value.pendingRemote == true) {
          _scheduleRemoteRetry(request);
        }
      });
    }
    final result = hasQuery
        ? ref.watch(searchSnapshotProvider(request))
        : ref.watch(exploreSnapshotProvider);
    final fresh = result.asData?.value;
    if (fresh != null) {
      if (hasQuery) {
        previousSearches[request] = fresh;
      } else {
        previousDiscovery = fresh;
      }
    }
    final source =
        fresh ?? (hasQuery ? previousSearches[request] : previousDiscovery);
    final data = source == null ? null : presentSnapshotForSession(ref, source);
    final refreshing =
        result.isLoading || (!hasQuery && fresh?.revalidating == true);
    final failed = result.hasError || (!hasQuery && fresh?.stale == true);
    final searchingRemote =
        hasQuery &&
        data?.pendingRemote == true &&
        remoteAttempts < remoteSearchRetryDelays.length;
    final competitions = _matching(data?.competitions, data, requestQuery);
    final teams = _matching(data?.teams, data, requestQuery);
    final follows =
        ref.watch(followsProvider).asData?.value ?? const <String>{};
    final players = hasQuery
        ? _matching(data?.players, data, requestQuery)
        : (ref
                      .watch(
                        playerSuggestionsProvider(followedTeamsKey(follows)),
                      )
                      .asData
                      ?.value ??
                  const <Entity>[])
              .take(12)
              .toList(growable: false);
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
                  hintText: 'Buscar equipos, jugadores, ligas...',
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
              query: requestQuery,
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

List<Entity> _matching(List<Entity>? entities, Snapshot? data, String query) =>
    entities
        ?.where((entity) => data?.demo != true || entity.matches(query))
        .toList(growable: false) ??
    const <Entity>[];

class _ExploreContent extends StatelessWidget {
  const _ExploreContent({
    required this.data,
    required this.hasQuery,
    required this.query,
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
    if (data == null && refreshing) {
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
          child: _ModeHeader(hasQuery: hasQuery, query: query),
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
        if (!searchingRemote && !refreshing && !failed && isEmpty)
          _BoxSliver(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: EmptyState(
              hasQuery
                  ? 'No encontramos resultados para “$query”.'
                  : 'Sin sugerencias disponibles',
              !hasQuery
                  ? 'Vuelve a intentarlo más tarde.'
                  : remoteExhausted
                  ? 'Seguimos buscando; intenta de nuevo en unos segundos.'
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
  const _ModeHeader({required this.hasQuery, required this.query});

  final bool hasQuery;
  final String query;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        hasQuery ? 'Resultados para “$query”' : 'Descubre FutBeat',
        key: ValueKey(
          hasQuery ? 'explore-results-title' : 'explore-discover-title',
        ),
        style: Theme.of(context).textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 4),
      Text(
        hasQuery
            ? 'Equipos, jugadores y competiciones que coinciden.'
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
    return Center(
      child: Semantics(
        label: message,
        liveRegion: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 14),
            Text(message),
          ],
        ),
      ),
    );
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

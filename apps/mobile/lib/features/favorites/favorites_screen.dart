import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models.dart';
import '../../core/live_realtime.dart';
import '../../core/providers.dart';
import '../../core/relevance.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';

class FavoritesScreen extends ConsumerStatefulWidget {
  const FavoritesScreen({super.key});

  @override
  ConsumerState<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends ConsumerState<FavoritesScreen> {
  LiveRealtimeClient? _liveClient;
  late final String _liveScope = 'favorites:${identityHashCode(this)}';
  Set<String>? _lastFollows;
  String? _observedKeys;
  String? _retriedFollowEmission;
  ({String keys, Snapshot snapshot})? _lastSnapshot;

  @override
  void dispose() {
    _liveClient?.clearScope(_liveScope);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(followsProvider, (previous, next) {
      final old = previous?.asData?.value;
      final current = next.asData?.value;
      if (old == null ||
          current == null ||
          current.isEmpty ||
          old.length != current.length ||
          !old.containsAll(current)) {
        return;
      }
      final keys = (current.toList()..sort()).join(',');
      final provider = favoritesSnapshotProvider(keys);
      if (_retriedFollowEmission != keys && ref.read(provider).hasError) {
        _retriedFollowEmission = keys;
        ref.invalidate(provider);
      }
    });
    final followState = ref.watch(followsProvider);
    final follows = _lastFollows = followState.asData?.value ?? _lastFollows;
    if (follows == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Siguiendo')),
        body: followState.hasError
            ? _LoadFailure(onRetry: () => ref.invalidate(followsProvider))
            : const ContentSkeleton(),
      );
    }

    final sortedKeys = follows.toList()..sort();
    final encodedKeys = sortedKeys.join(',');
    ref.listen(favoritesAccountChangesProvider, (_, next) {
      if (next is! AsyncData<String?>) return;
      // A request started under the guest scope can be cancelled by the
      // transport on sign-in. The same follow keys still need a fresh read.
      _lastSnapshot = null;
      _retriedFollowEmission = null;
      if (encodedKeys.isNotEmpty) {
        ref.invalidate(favoritesSnapshotProvider(encodedKeys));
      }
    });
    final request = follows.isEmpty
        ? null
        : ref.watch(favoritesSnapshotProvider(encodedKeys));
    if (_observedKeys != encodedKeys) {
      _observedKeys = encodedKeys;
      _retriedFollowEmission = null;
      // A kept-alive provider may have failed before this screen subscribed
      // to account changes. Retry that retained error once on entry.
      if (request?.hasError == true) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              _observedKeys == encodedKeys &&
              ref.read(favoritesSnapshotProvider(encodedKeys)).hasError) {
            ref.invalidate(favoritesSnapshotProvider(encodedKeys));
          }
        });
      }
    }
    final current = request?.asData?.value;
    if (current != null) {
      _lastSnapshot = (keys: encodedKeys, snapshot: current);
    }
    // Keep a refresh fallback only for the same selection. An old response
    // may include the new favorite incidentally (e.g. as an opponent) and
    // must not stand in for its data or keep its matches subscribed to LIVE.
    final cached = _lastSnapshot;
    final repository = ref.exists(repositoryProvider)
        ? ref.read(repositoryProvider)
        : null;
    final local = follows.isEmpty || repository is! ApiRepository
        ? null
        : ref.watch(localFavoritesMetadataProvider(encodedKeys)).value ??
              repository.knownFavoriteMetadata(follows);
    final remote =
        current ?? (cached?.keys == encodedKeys ? cached?.snapshot : null);
    final missingKnown =
        local != null &&
        remote != null &&
        (local.teams.any((e) => remote.team(e.id) == null) ||
            local.players.any((e) => remote.player(e.id) == null) ||
            local.competitions.any((e) => remote.competition(e.id) == null));
    final snapshot = remote == null
        ? local
        : missingKnown
        ? Snapshot.combineFavoriteCatalogs([remote, local], incomplete: true)
        : remote;
    final client = ref.read(liveRealtimeClientProvider);
    if (!identical(_liveClient, client)) {
      _liveClient?.clearScope(_liveScope);
      _liveClient = client;
    }
    // Retain cached presentation for refresh failures, but an empty follow
    // selection must not keep the old snapshot's matches subscribed to LIVE.
    final favoriteMatchIds = follows.isEmpty
        ? const <String>[]
        : snapshot?.matches.map((match) => match.id).toList() ??
              const <String>[];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) client.setScope(_liveScope, favoriteMatchIds);
    });
    final updates =
        ref.watch(liveMatchUpdatesProvider).asData?.value ??
        const <String, LiveMatchUpdate>{};
    final data = snapshot == null
        ? null
        : presentSnapshotForSession(ref, snapshot).withLiveUpdates(updates);
    final hub = data == null
        ? const FollowingHubData.empty()
        : FollowingHubData.from(data, follows);
    final refreshing = request?.isLoading == true && data != null;
    final staleError =
        followState.hasError ||
        data?.stale == true ||
        (request?.hasError == true && data != null);

    Future<void> refreshFavorites() async {
      if (encodedKeys.isEmpty) return;
      try {
        final provider = favoritesSnapshotProvider(encodedKeys);
        ref.invalidate(provider);
        await ref.read(provider.future);
      } catch (_) {
        // The request state retains the visible metadata and recovery action.
      }
    }

    if (follows.isNotEmpty && data == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Siguiendo')),
        body: request?.hasError == true
            ? _LoadFailure(
                onRetry: () =>
                    ref.invalidate(favoritesSnapshotProvider(encodedKeys)),
              )
            : const ContentSkeleton(),
      );
    }

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(title: const Text('Siguiendo')),
        body: Column(
          children: [
            if (refreshing) const LinearProgressIndicator(minHeight: 2),
            if (staleError)
              _CachedNotice(
                onRetry: () {
                  ref.invalidate(followsProvider);
                  if (encodedKeys.isNotEmpty) {
                    ref.invalidate(favoritesSnapshotProvider(encodedKeys));
                  }
                },
              ),
            _FollowingSummary(hub),
            const TabBar(
              tabs: [
                Tab(text: 'Equipos'),
                Tab(text: 'Jugadores'),
                Tab(text: 'Competiciones'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _FollowingList(
                    type: 'team',
                    onRefresh: refreshFavorites,
                    missingIds: hub.missingIds['team'] ?? const [],
                    onRetry: () =>
                        ref.invalidate(favoritesSnapshotProvider(encodedKeys)),
                    emptyText: 'Aún no sigues equipos.',
                    items: [
                      for (final team in hub.teams)
                        _FollowingRowData.team(team, hub.data!),
                    ],
                  ),
                  _FollowingList(
                    type: 'player',
                    onRefresh: refreshFavorites,
                    missingIds: hub.missingIds['player'] ?? const [],
                    onRetry: () =>
                        ref.invalidate(favoritesSnapshotProvider(encodedKeys)),
                    emptyText: 'Aún no sigues jugadores.',
                    items: [
                      for (final player in hub.players)
                        _FollowingRowData.player(player, hub.data!),
                    ],
                  ),
                  _FollowingList(
                    type: 'competition',
                    onRefresh: refreshFavorites,
                    missingIds: hub.missingIds['competition'] ?? const [],
                    onRetry: () =>
                        ref.invalidate(favoritesSnapshotProvider(encodedKeys)),
                    emptyText: 'Aún no sigues competiciones.',
                    items: [
                      for (final competition in hub.competitions)
                        _FollowingRowData.competition(competition),
                    ],
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

class FollowingHubData {
  const FollowingHubData({
    required this.data,
    required this.teams,
    required this.players,
    required this.competitions,
    this.missingIds = const {},
  });

  const FollowingHubData.empty()
    : data = null,
      teams = const [],
      players = const [],
      competitions = const [],
      missingIds = const {};

  factory FollowingHubData.from(Snapshot data, Set<String> follows) {
    bool followed(String type, Entity entity) {
      final canonical = data.resolveEntityId(entity.id);
      return follows.any((key) {
        final prefix = '$type:';
        return key.startsWith(prefix) &&
            data.resolveEntityId(key.substring(prefix.length)) == canonical;
      });
    }

    List<Entity> sorted(Iterable<Entity> values) {
      final unique = <String, Entity>{};
      for (final entity in values) {
        final id = data.resolveEntityId(entity.id);
        final previous = unique[id];
        if (previous == null || entity.id == id) unique[id] = entity;
      }
      return unique.values.toList()..sort((left, right) {
        final byName = left.displayName.toLowerCase().compareTo(
          right.displayName.toLowerCase(),
        );
        return byName != 0 ? byName : left.id.compareTo(right.id);
      });
    }

    final teams = sorted(
      data.teams.where((entity) => followed('team', entity)),
    );
    final players = sorted(
      data.players.where((entity) => followed('player', entity)),
    );
    final competitions = sorted(
      data.competitions.where((entity) => followed('competition', entity)),
    );
    List<String> missing(String type, List<Entity> available) {
      final known = available.map((e) => data.resolveEntityId(e.id)).toSet();
      return {
        for (final key in follows)
          if (key.startsWith('$type:') && key.length > type.length + 1)
            data.resolveEntityId(key.substring(type.length + 1)),
      }.difference(known).toList()..sort();
    }

    return FollowingHubData(
      data: data,
      teams: teams,
      players: players,
      competitions: competitions,
      missingIds: {
        'team': missing('team', teams),
        'player': missing('player', players),
        'competition': missing('competition', competitions),
      },
    );
  }

  final Snapshot? data;
  final List<Entity> teams;
  final List<Entity> players;
  final List<Entity> competitions;
  final Map<String, List<String>> missingIds;
}

class _FollowingSummary extends StatelessWidget {
  const _FollowingSummary(this.hub);
  final FollowingHubData hub;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
    child: Row(
      children: [
        const Icon(Icons.star_rounded, color: lime, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '${hub.teams.length + (hub.missingIds['team']?.length ?? 0)} equipos · ${hub.players.length + (hub.missingIds['player']?.length ?? 0)} jugadores · '
            '${hub.competitions.length + (hub.missingIds['competition']?.length ?? 0)} competiciones',
            key: const ValueKey('following-summary'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: muted, fontSize: 12),
          ),
        ),
      ],
    ),
  );
}

class _FollowingList extends StatelessWidget {
  const _FollowingList({
    required this.type,
    required this.emptyText,
    required this.items,
    this.missingIds = const [],
    this.onRetry,
    required this.onRefresh,
  });

  final String type;
  final String emptyText;
  final List<_FollowingRowData> items;
  final List<String> missingIds;
  final VoidCallback? onRetry;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty && missingIds.isEmpty) {
      return RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          key: PageStorageKey('following-$type-empty'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(20),
          children: [
            EmptyState(
              emptyText,
              'Explora FutBeat para encontrar nuevos favoritos.',
              icon: Icons.star_border_rounded,
            ),
            FilledButton.icon(
              key: ValueKey('following-explore-$type'),
              onPressed: () => context.go('/explore'),
              icon: const Icon(Icons.search_rounded),
              label: const Text('Explorar'),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.builder(
        key: PageStorageKey('following-$type'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        itemCount:
            items.length +
            missingIds.length +
            (missingIds.isEmpty ? 0 : 1) +
            (type == 'team' ? 1 : 0),
        itemBuilder: (context, rowIndex) {
          if (type == 'team' && rowIndex == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
              child: Text(
                'Equipos favoritos',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            );
          }
          final index = rowIndex - (type == 'team' ? 1 : 0);
          if (index >= items.length) {
            if (index == items.length + missingIds.length) {
              return TextButton.icon(
                key: ValueKey('following-retry-$type'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Actualizar información'),
              );
            }
            final id = missingIds[index - items.length];
            final label = switch (type) {
              'team' => 'Equipo guardado',
              'player' => 'Jugador guardado',
              _ => 'Competición guardada',
            };
            // This is an existing saved follow, not a fabricated entity/profile.
            // Only explicit server redirects determine the destination ID.
            return Card(
              child: ListTile(
                key: ValueKey('following-missing-$type-$id'),
                leading: const Icon(Icons.star_outline_rounded, color: muted),
                title: Text(label),
                subtitle: const Text(
                  'Tu seguimiento está guardado. Información aún no disponible.',
                ),
                onTap: () => context.push('/$type/$id'),
                trailing: FollowButton(type, id, label: label),
              ),
            );
          }
          return _FollowingRow(
            key: ValueKey('following-$type-${items[index].entity.id}'),
            type: type,
            item: items[index],
          );
        },
      ),
    );
  }
}

class _FollowingRowData {
  const _FollowingRowData(this.entity, this.subtitle, {this.detail});

  factory _FollowingRowData.team(Entity team, Snapshot data) {
    final parts = <String>[if (team.country.isNotEmpty) team.country];
    final competitionId = team.json['competitionId']?.toString();
    final competition = competitionId == null
        ? null
        : data.competition(competitionId);
    if (competition != null) parts.add(competition.displayName);
    final canonicalTeam = data.resolveEntityId(team.id);
    final candidates =
        data.matches
            .where(
              (match) =>
                  (data.resolveEntityId(match.homeId) == canonicalTeam ||
                      data.resolveEntityId(match.awayId) == canonicalTeam) &&
                  (match.isLive || match.isUpcoming),
            )
            .toList()
          ..sort((a, b) {
            if (a.isLive != b.isLive) return a.isLive ? -1 : 1;
            return a.startTime.compareTo(b.startTime);
          });
    final next = candidates.firstOrNull;
    String? detail;
    if (next != null) {
      final opponentId = data.resolveEntityId(next.homeId) == canonicalTeam
          ? next.awayId
          : next.homeId;
      final opponent = data.team(opponentId)?.displayName;
      if (opponent != null) {
        detail = next.isLive
            ? 'EN VIVO · vs $opponent'
            : 'Próximo · vs $opponent';
      }
    }
    return _FollowingRowData(team, parts.join(' · '), detail: detail);
  }

  factory _FollowingRowData.player(Entity player, Snapshot data) {
    final parts = <String>[];
    final teamId = player.json['teamId']?.toString();
    final club =
        (teamId == null ? null : data.team(teamId)?.displayName) ??
        [
          player.json['teamName'],
          player.json['clubName'],
          player.json['currentTeamName'],
        ].whereType<String>().where((s) => s.trim().isNotEmpty).firstOrNull;
    if (club != null) parts.add(club);
    final position = playerPositionLabel(
      player.json['position']?.toString() ?? '',
    );
    if (position.isNotEmpty) parts.add(position);
    return _FollowingRowData(player, parts.join(' · '));
  }

  factory _FollowingRowData.competition(Entity competition) =>
      _FollowingRowData(competition, entityCountryLabel(competition) ?? '');

  final Entity entity;
  final String subtitle;
  final String? detail;
}

class _FollowingRow extends StatelessWidget {
  const _FollowingRow({required this.type, required this.item, super.key});

  final String type;
  final _FollowingRowData item;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    child: Semantics(
      button: true,
      label: 'Abrir ${item.entity.displayName}',
      child: ListTile(
        minTileHeight: 64,
        leading: EntityAvatar(item.entity, size: 42),
        title: Text(
          item.entity.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: item.subtitle.isEmpty && item.detail == null
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (item.subtitle.isNotEmpty)
                    Text(
                      item.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (item.detail case final detail?)
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: lime, fontSize: 11),
                    ),
                ],
              ),
        trailing: FollowButton(
          type,
          item.entity.id,
          label: item.entity.displayName,
          compact: true,
        ),
        onTap: () => context.push('/$type/${item.entity.id}'),
      ),
    ),
  );
}

class _CachedNotice extends StatelessWidget {
  const _CachedNotice({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    child: IconButton(
      tooltip: 'Reintentar actualización',
      onPressed: onRetry,
      icon: const Icon(Icons.refresh, color: muted),
    ),
  );
}

class _LoadFailure extends StatelessWidget {
  const _LoadFailure({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const EmptyState(
          'No pudimos cargar tus seguidos',
          'Revisa tu conexión e intenta nuevamente.',
          icon: Icons.cloud_off_outlined,
        ),
        FilledButton(onPressed: onRetry, child: const Text('Reintentar')),
      ],
    ),
  );
}

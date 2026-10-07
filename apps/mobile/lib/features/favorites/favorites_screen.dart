import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models.dart';
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
  Set<String>? _lastFollows;
  Snapshot? _lastSnapshot;

  @override
  Widget build(BuildContext context) {
    final followState = ref.watch(followsProvider);
    ref.listen(followsProvider, (_, next) {
      final value = next.asData?.value;
      if (value != null && mounted) setState(() => _lastFollows = value);
    });
    final follows = followState.asData?.value ?? _lastFollows;
    if (follows == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Siguiendo')),
        body: followState.hasError
            ? _LoadFailure(onRetry: () => ref.invalidate(followsProvider))
            : const Center(child: CircularProgressIndicator()),
      );
    }

    final sortedKeys = follows.toList()..sort();
    final encodedKeys = sortedKeys.join(',');
    final request = follows.isEmpty
        ? null
        : ref.watch(favoritesSnapshotProvider(encodedKeys));
    if (request != null) {
      ref.listen(favoritesSnapshotProvider(encodedKeys), (_, next) {
        final value = next.asData?.value;
        if (value != null && mounted) setState(() => _lastSnapshot = value);
      });
    }
    final snapshot = request?.asData?.value ?? _lastSnapshot;
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
        followState.hasError || (request?.hasError == true && data != null);

    if (follows.isNotEmpty && data == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Siguiendo')),
        body: request?.hasError == true
            ? _LoadFailure(
                onRetry: () =>
                    ref.invalidate(favoritesSnapshotProvider(encodedKeys)),
              )
            : const Center(child: CircularProgressIndicator()),
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
                    emptyText: 'Aún no sigues equipos.',
                    items: [
                      for (final team in hub.teams)
                        _FollowingRowData.team(team, hub.data!),
                    ],
                  ),
                  _FollowingList(
                    type: 'player',
                    emptyText: 'Aún no sigues jugadores.',
                    items: [
                      for (final player in hub.players)
                        _FollowingRowData.player(player, hub.data!),
                    ],
                  ),
                  _FollowingList(
                    type: 'competition',
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
  });

  const FollowingHubData.empty()
    : data = null,
      teams = const [],
      players = const [],
      competitions = const [];

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

    return FollowingHubData(
      data: data,
      teams: sorted(data.teams.where((entity) => followed('team', entity))),
      players: sorted(
        data.players.where((entity) => followed('player', entity)),
      ),
      competitions: sorted(
        data.competitions.where((entity) => followed('competition', entity)),
      ),
    );
  }

  final Snapshot? data;
  final List<Entity> teams;
  final List<Entity> players;
  final List<Entity> competitions;
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
            '${hub.teams.length} equipos · ${hub.players.length} jugadores · '
            '${hub.competitions.length} competiciones',
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
  });

  final String type;
  final String emptyText;
  final List<_FollowingRowData> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return ListView(
        key: PageStorageKey('following-$type-empty'),
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
      );
    }
    return ListView.builder(
      key: PageStorageKey('following-$type'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: items.length,
      itemBuilder: (context, index) => _FollowingRow(
        key: ValueKey('following-$type-${items[index].entity.id}'),
        type: type,
        item: items[index],
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
    final candidates =
        data.matches
            .where(
              (match) =>
                  (match.homeId == team.id || match.awayId == team.id) &&
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
      final opponentId = next.homeId == team.id ? next.awayId : next.homeId;
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
    final club = teamId == null ? null : data.team(teamId)?.displayName;
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
  Widget build(BuildContext context) => Material(
    color: Colors.amber.withValues(alpha: .10),
    child: ListTile(
      dense: true,
      leading: const Icon(Icons.cloud_off_outlined, color: Colors.amber),
      title: const Text('Mostrando tus seguidos guardados'),
      trailing: TextButton(onPressed: onRetry, child: const Text('Reintentar')),
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../shared/widgets.dart';
import '../matches/matches_screen.dart';

class FavoritesScreen extends ConsumerWidget {
  const FavoritesScreen({super.key});

  bool _isFollowedEntity(
    Set<String> follows,
    Snapshot data,
    String type,
    String id,
  ) {
    final prefix = '$type:';
    for (final key in follows) {
      if (!key.startsWith(prefix)) continue;
      final originalId = key.substring(prefix.length);
      if (data.resolveEntityId(originalId) == id) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final followState = ref.watch(followsProvider);
    final follows = followState.asData?.value;
    final sortedKeys = follows == null ? <String>[] : (follows.toList()..sort());
    final encodedKeys = sortedKeys.join(',');
    final favorites = follows != null && follows.isNotEmpty
        ? ref.watch(favoritesSnapshotProvider(encodedKeys))
        : null;
    final updates =
        ref.watch(liveMatchUpdatesProvider).asData?.value ??
        const <String, LiveMatchUpdate>{};

    return Scaffold(
      appBar: AppBar(title: const Text('Siguiendo')),
      body: followState.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, stack) => Center(
          child: TextButton(
            onPressed: () => ref.invalidate(followsProvider),
            child: const Text(
              'No se pudo cargar el seguimiento · Reintentar',
            ),
          ),
        ),
        data: (currentFollows) {
          if (currentFollows.isEmpty) {
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const EmptyState(
                  'Tu fútbol empieza aquí',
                  'Toca la estrella de un equipo, jugador, competición o partido para seguirlo.',
                  icon: Icons.star_border,
                ),
                FilledButton(
                  onPressed: () => context.go('/explore'),
                  child: const Text('Explorar equipos'),
                ),
              ],
            );
          }

          final request = favorites!;
          return request.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, stack) => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const EmptyState(
                    'No pudimos cargar tus favoritos',
                    'Revisa tu conexión e intenta nuevamente.',
                    icon: Icons.cloud_off,
                  ),
                  FilledButton(
                    onPressed: () async {
                      ref.invalidate(favoritesSnapshotProvider(encodedKeys));
                      try {
                        await ref.read(
                          favoritesSnapshotProvider(encodedKeys).future,
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
            data: (snapshot) {
              final data = snapshot.withLiveUpdates(updates);
              return ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  for (final team in data.teams.where(
                    (entity) => _isFollowedEntity(
                      currentFollows,
                      data,
                      'team',
                      entity.id,
                    ),
                  ))
                    EntityTile(team, 'team'),
                  for (final player in data.players.where(
                    (entity) => _isFollowedEntity(
                      currentFollows,
                      data,
                      'player',
                      entity.id,
                    ),
                  ))
                    EntityTile(player, 'player'),
                  for (final competition in data.competitions.where(
                    (entity) => _isFollowedEntity(
                      currentFollows,
                      data,
                      'competition',
                      entity.id,
                    ),
                  ))
                    EntityTile(competition, 'competition'),
                  for (final match in data.matches.where(
                    (item) => currentFollows.contains('match:${item.id}'),
                  ))
                    MatchCard(match, data),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

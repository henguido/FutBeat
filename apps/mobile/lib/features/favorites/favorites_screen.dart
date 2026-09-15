import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../shared/widgets.dart';
import '../matches/matches_screen.dart';

class FavoritesScreen extends ConsumerWidget {
  const FavoritesScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('Siguiendo')),
    body: DataView(
      builder: (data) => ref
          .watch(followsProvider)
          .when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, stack) => Center(
              child: TextButton(
                onPressed: () => ref.invalidate(followsProvider),
                child: const Text(
                  'No se pudo cargar el seguimiento · Reintentar',
                ),
              ),
            ),
            data: (follows) => ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (follows.isEmpty) ...[
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
                for (final team in data.teams.where(
                  (e) => follows.contains('team:${e.id}'),
                ))
                  EntityTile(team, 'team'),
                for (final player in data.players.where(
                  (e) => follows.contains('player:${e.id}'),
                ))
                  EntityTile(player, 'player'),
                for (final competition in data.competitions.where(
                  (e) => follows.contains('competition:${e.id}'),
                ))
                  EntityTile(competition, 'competition'),
                for (final match in data.matches.where(
                  (e) => follows.contains('match:${e.id}'),
                ))
                  MatchCard(match, data),
              ],
            ),
          ),
    ),
  );
}

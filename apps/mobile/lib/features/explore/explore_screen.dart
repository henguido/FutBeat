import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

class _ExploreScreenState extends ConsumerState<ExploreScreen> {
  String query = '';

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text(
            'Explorar',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        body: DataView(
          builder: (data) {
            final hasQuery = query.trim().isNotEmpty;
            final follows =
                ref.watch(followsProvider).asData?.value ?? <String>{};
            final preference = ref.watch(preferenceProvider).asData?.value;
            final country = preference?.effectiveCountry;

            final competitions = data.demo
                ? data.competitions.where((e) => e.matches(query)).toList()
                : rankSearchEntities(
                    data: data,
                    entities: data.competitions,
                    type: 'competition',
                    query: query,
                    follows: follows,
                    userCountry: country,
                    limit: hasQuery ? 40 : 12,
                  );
            final teams = data.demo
                ? data.teams.where((e) => e.matches(query)).toList()
                : rankSearchEntities(
                    data: data,
                    entities: data.teams,
                    type: 'team',
                    query: query,
                    follows: follows,
                    userCountry: country,
                    limit: hasQuery ? 50 : 12,
                  );
            final players = data.demo
                ? data.players.where((e) => e.matches(query)).toList()
                : hasQuery
                ? rankSearchEntities(
                    data: data,
                    entities: data.players,
                    type: 'player',
                    query: query,
                    follows: follows,
                    userCountry: country,
                    limit: 50,
                  )
                : <dynamic>[];

            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                TextField(
                  decoration: const InputDecoration(
                    hintText: 'Buscar equipos, jugadores, ligas...',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (value) => setState(() => query = value),
                ),
                const SizedBox(height: 20),
                if (data.demo) const DemoNotice(),
                if (query.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF253E2B), panel],
                      ),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'COSTA RICA',
                          style: TextStyle(
                            color: lime,
                            letterSpacing: 2,
                            fontSize: 11,
                          ),
                        ),
                        SizedBox(height: 12),
                        Text(
                          'Fútbol que\nnos une',
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(height: 12),
                        Text(
                          'Nuestra liga. Nuestra pasión.',
                          style: TextStyle(color: muted),
                        ),
                      ],
                    ),
                  ),
                if (hasQuery &&
                    competitions.isEmpty &&
                    teams.isEmpty &&
                    players.isEmpty)
                  const EmptyState(
                    'No encontramos resultados',
                    'Prueba con otro nombre o abreviación.',
                    icon: Icons.search_off,
                  ),
                if (competitions.isNotEmpty)
                  heading(
                    context,
                    !data.demo && !hasQuery
                        ? 'Ligas destacadas'
                        : 'Competiciones',
                  ),
                for (final entity in competitions)
                  EntityTile(entity, 'competition'),
                if (teams.isNotEmpty)
                  heading(
                    context,
                    !data.demo && !hasQuery ? 'Equipos destacados' : 'Equipos',
                  ),
                for (final entity in teams) EntityTile(entity, 'team'),
                if (players.isNotEmpty) heading(context, 'Jugadores'),
                for (final entity in players) EntityTile(entity, 'player'),
              ],
            );
          },
        ),
      );
}

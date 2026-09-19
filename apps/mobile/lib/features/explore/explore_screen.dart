import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/interests.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';

class ExploreScreen extends ConsumerStatefulWidget {
  const ExploreScreen({super.key});

  @override
  ConsumerState<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends ConsumerState<ExploreScreen> {
  String query = '';
  String requestQuery = '';
  Timer? debounce;

  List<Entity> _prioritizeFollowed(
    Iterable<Entity> entities,
    Set<String> follows,
    String type,
    int limit,
  ) {
    final followed = <Entity>[];
    final rest = <Entity>[];
    for (final entity in entities) {
      (follows.contains('$type:${entity.id}') ? followed : rest).add(entity);
    }
    return [...followed, ...rest].take(limit).toList();
  }

  @override
  void dispose() {
    debounce?.cancel();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    setState(() => query = value);
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() => requestQuery = value.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final follows = ref.watch(followsProvider).asData?.value ?? <String>{};
    final preference = ref.watch(preferenceProvider).asData?.value;
    final country =
        preference?.effectiveCountry ?? ref.watch(detectedCountryProvider);
    final request = (query: requestQuery, country: country);
    final result = ref.watch(searchSnapshotProvider(request));

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
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Buscar equipos, jugadores, ligas...',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: _onQueryChanged,
            ),
          ),
          Expanded(
            child: result.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, stack) => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const EmptyState(
                      'No pudimos cargar la búsqueda',
                      'Revisa tu conexión e intenta nuevamente.',
                      icon: Icons.cloud_off,
                    ),
                    FilledButton(
                      onPressed: () async {
                        ref.invalidate(searchSnapshotProvider(request));
                        try {
                          await ref.read(
                            searchSnapshotProvider(request).future,
                          );
                        } catch (_) {
                          // The error state will remain visible with retry enabled.
                        }
                      },
                      child: const Text('Reintentar'),
                    ),
                  ],
                ),
              ),
              data: (data) {
                final hasQuery = requestQuery.isNotEmpty;
                final hasInput = query.trim().isNotEmpty;

                final competitions = data.demo
                    ? data.competitions
                          .where((entity) => entity.matches(requestQuery))
                          .toList()
                    : _prioritizeFollowed(
                        data.competitions,
                        follows,
                        'competition',
                        hasQuery ? 40 : 12,
                      );
                final teams = data.demo
                    ? data.teams
                          .where((entity) => entity.matches(requestQuery))
                          .toList()
                    : _prioritizeFollowed(
                        data.teams,
                        follows,
                        'team',
                        hasQuery ? 50 : 12,
                      );
                final players = data.demo
                    ? data.players
                          .where((entity) => entity.matches(requestQuery))
                          .toList()
                    : hasQuery
                    ? _prioritizeFollowed(data.players, follows, 'player', 50)
                    : <Entity>[];

                return ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                  children: [
                    if (data.demo) const DemoNotice(),
                    if (!hasInput)
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
                        !data.demo && !hasQuery
                            ? 'Equipos destacados'
                            : 'Equipos',
                      ),
                    for (final entity in teams) EntityTile(entity, 'team'),
                    if (players.isNotEmpty) heading(context, 'Jugadores'),
                    for (final entity in players) EntityTile(entity, 'player'),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

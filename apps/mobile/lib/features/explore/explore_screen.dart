import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../shared/widgets.dart';

class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key});
  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
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
        final competitions = data.competitions.where((e) => e.matches(query));
        final teams = data.teams.where((e) => e.matches(query));
        final players = data.players.where((e) => e.matches(query));
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
            if (competitions.isEmpty && teams.isEmpty && players.isEmpty)
              const EmptyState(
                'No encontramos resultados',
                'Prueba otro nombre o un alias como LDA o Sapri.',
                icon: Icons.search_off,
              ),
            if (competitions.isNotEmpty) heading(context, 'Competiciones'),
            for (final entity in competitions)
              EntityTile(entity, 'competition'),
            if (teams.isNotEmpty) heading(context, 'Equipos'),
            for (final entity in teams) EntityTile(entity, 'team'),
            if (players.isNotEmpty) heading(context, 'Jugadores'),
            for (final entity in players) EntityTile(entity, 'player'),
          ],
        );
      },
    ),
  );
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';

class ExploreScreen extends ConsumerStatefulWidget {
  const ExploreScreen({super.key});
  @override
  ConsumerState<ExploreScreen> createState() => _ExploreScreenState();
}

/// Bounded re-queries while the server discovers players remotely.
const remoteSearchRetryDelays = [
  Duration(seconds: 3),
  Duration(seconds: 5),
  Duration(seconds: 8),
];

class _ExploreScreenState extends ConsumerState<ExploreScreen> {
  String requestQuery = '';
  Timer? debounce;
  Timer? remoteRetry;
  int remoteAttempts = 0;
  Snapshot? previous;
  bool typing = false;
  @override
  void dispose() {
    debounce?.cancel();
    remoteRetry?.cancel();
    super.dispose();
  }

  void _scheduleRemoteRetry(({String query, String? country}) request) {
    if (remoteRetry != null ||
        remoteAttempts >= remoteSearchRetryDelays.length) {
      return;
    }
    remoteRetry = Timer(remoteSearchRetryDelays[remoteAttempts], () {
      if (!mounted) return;
      setState(() {
        remoteAttempts++;
        remoteRetry = null;
      });
      ref.invalidate(searchSnapshotProvider(request));
    });
  }

  void _onQueryChanged(String value) {
    debounce?.cancel();
    remoteRetry?.cancel();
    remoteRetry = null;
    remoteAttempts = 0;
    setState(() => typing = true);
    debounce = Timer(const Duration(milliseconds: 275), () {
      if (!mounted) return;
      setState(() {
        requestQuery = value.trim().length >= 2 ? value.trim() : '';
        typing = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasQuery = requestQuery.isNotEmpty;
    final request = (query: requestQuery, country: null as String?);
    if (hasQuery) {
      ref.listen(searchSnapshotProvider(request), (_, next) {
        // Ignore the refresh-in-progress state (it still carries old data).
        if (!next.isLoading && next.asData?.value.pendingRemote == true) {
          _scheduleRemoteRetry(request);
        }
      });
    }
    final result = hasQuery
        ? ref.watch(searchSnapshotProvider(request))
        : ref.watch(exploreSnapshotProvider);
    final fresh = result.asData?.value;
    if (fresh != null) previous = fresh;
    final data = fresh ?? previous;
    final searchingRemote =
        hasQuery &&
        data?.pendingRemote == true &&
        remoteAttempts < remoteSearchRetryDelays.length;
    final competitions =
        data?.competitions
            .where((e) => !data.demo || e.matches(requestQuery))
            .toList() ??
        <Entity>[];
    final teams =
        data?.teams
            .where((e) => !data.demo || e.matches(requestQuery))
            .toList() ??
        <Entity>[];
    final players = hasQuery
        ? data?.players
                  .where((e) => !data.demo || e.matches(requestQuery))
                  .toList() ??
              <Entity>[]
        : <Entity>[];
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
          if (typing || result.isLoading)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              children: [
                if (data?.demo == true) const DemoNotice(),
                if (result.hasError) ...[
                  Text(
                    data == null ? 'No pudimos cargar la búsqueda' : 'No pudimos actualizar. Conservamos los resultados disponibles.',
                  ),
                  TextButton(
                    onPressed: () {
                      if (hasQuery) {
                        ref.invalidate(searchSnapshotProvider(request));
                      } else {
                        ref.invalidate(exploreSnapshotProvider);
                      }
                    },
                    child: const Text('Reintentar'),
                  ),
                ],
                if (searchingRemote) const _RemoteSearchNotice(),
                if (!searchingRemote &&
                    !result.isLoading &&
                    !result.hasError &&
                    data != null &&
                    competitions.isEmpty &&
                    teams.isEmpty &&
                    players.isEmpty)
                  EmptyState(
                    hasQuery
                        ? 'No encontramos resultados'
                        : 'Sin sugerencias disponibles',
                    !hasQuery
                        ? ''
                        : data.pendingRemote
                        ? 'Seguimos buscando; intenta de nuevo en unos segundos.'
                        : 'Prueba con otro nombre o abreviación.',
                  ),
                if (competitions.isNotEmpty)
                  heading(
                    context,
                    hasQuery ? 'Competiciones' : 'Competiciones destacadas',
                  ),
                for (final entity in competitions)
                  EntityTile(entity, 'competition', showFollow: true),
                if (teams.isNotEmpty)
                  heading(context, hasQuery ? 'Equipos' : 'Equipos sugeridos'),
                for (final entity in teams)
                  EntityTile(entity, 'team', showFollow: true),
                if (players.isNotEmpty) heading(context, 'Jugadores'),
                for (final entity in players) EntityTile(entity, 'player'),
              ],
            ),
          ),
        ],
      ),
    );
  }
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

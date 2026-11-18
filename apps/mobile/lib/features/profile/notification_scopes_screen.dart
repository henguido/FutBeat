import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/notification_scopes.dart';
import '../../core/push.dart';

const _scopeNames = {'player': 'Jugador', 'team': 'Equipo', 'match': 'Partido'};
const _kindNames = {
  'starter': 'Titular confirmado',
  'bench': 'Suplente confirmado',
  'goal': 'Gol',
  'penalty_goal': 'Gol de penal',
  'assist': 'Asistencia',
  'sub_in': 'Entra al campo',
  'sub_out': 'Sale del campo',
  'yellow_card': 'Tarjeta amarilla',
  'red_card': 'Tarjeta roja',
  'penalty_missed': 'Penal fallado',
  'goal_annulled': 'Gol anulado o corregido',
  'kickoff': 'Inicio',
  'halftime': 'Descanso',
  'final': 'Final',
  'goal_for': 'Gol a favor',
  'goal_against': 'Gol en contra',
  'substitution': 'Sustitución',
};

class NotificationScopesScreen extends ConsumerStatefulWidget {
  const NotificationScopesScreen({super.key});
  @override
  ConsumerState<NotificationScopesScreen> createState() => _ScopesState();
}

class _ScopesState extends ConsumerState<NotificationScopesScreen> {
  NotificationScopes? value;
  String? owner;
  String? error;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final service = ref.read(pushServiceProvider);
    final uid = service.userId;
    setState(() {
      busy = true;
      error = null;
      value = null;
      owner = uid;
    });
    try {
      final result = await service.readNotificationScopes();
      if (mounted && service.userId == uid) setState(() => value = result);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'No pudimos cargar estas alertas. Comprueba tu conexión e inicia sesión.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _save(String scope, String kind, bool? enabled) async {
    final service = ref.read(pushServiceProvider);
    final uid = owner;
    if (busy || service.userId != uid) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await service.setNotificationScope(scope, kind, enabled);
      if (mounted && service.userId == uid) setState(() => value = result);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'El cambio no se ha confirmado. Reintenta al recuperar la conexión.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(pushServiceProvider);
    final current = service.userId == owner ? value : null;
    return Scaffold(
      appBar: AppBar(title: const Text('Alertas por seguimiento')),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Jugador: solo sus eventos confirmados. Equipo y partido: sus acontecimientos. '
              'Estas preferencias no cambian a quién sigues. Una elección aquí prevalece '
              'sobre la preferencia general; puedes restablecerla con el botón de reinicio.',
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null || current == null && !busy)
            ListTile(
              title: Text(error ?? 'Vuelve a cargar tus preferencias.'),
              trailing: TextButton(
                onPressed: busy ? null : _load,
                child: const Text('Reintentar'),
              ),
            ),
          if (current != null)
            for (final scope in current.scopes.entries)
              ExpansionTile(
                title: Text(_scopeNames[scope.key]!),
                children: [
                  for (final kind in scope.value.entries)
                    ListTile(
                      title: Text(_kindNames[kind.key]!),
                      subtitle: Text(switch (kind.value.coverage) {
                        'partial' => 'Depende de los datos del proveedor',
                        'rare' => 'Poco frecuente',
                        _ => 'Según cobertura del partido',
                      }),
                      leading: Switch(
                        value: kind.value.enabled,
                        onChanged: busy
                            ? null
                            : (v) => _save(scope.key, kind.key, v),
                      ),
                      trailing: kind.value.explicit == null
                          ? null
                          : IconButton(
                              tooltip: 'Usar preferencia general',
                              icon: const Icon(Icons.restart_alt),
                              onPressed: busy
                                  ? null
                                  : () => _save(scope.key, kind.key, null),
                            ),
                    ),
                ],
              ),
        ],
      ),
    );
  }
}

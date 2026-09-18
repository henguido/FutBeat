import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../core/push.dart';
import 'country_preferences.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final email = TextEditingController();
  final password = TextEditingController();
  final displayName = TextEditingController();

  UserProfileSettings settings = const UserProfileSettings();
  bool busy = false;
  bool loaded = false;
  String? message;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    displayName.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final service = ref.read(pushServiceProvider);
    await service.restore();
    final value = await service.loadProfileSettings();
    if (!mounted) return;
    setState(() {
      settings = value;
      displayName.text = value.displayName ?? '';
      loaded = true;
    });
  }

  Future<void> action(Future<void> Function() work, String success) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await work();
      await _load();
      if (mounted) setState(() => message = success);
    } catch (_) {
      if (mounted) {
        setState(() => message = 'No se pudo completar la operación.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> saveSettings(UserProfileSettings value) async {
    setState(() {
      settings = value;
      message = null;
    });
    try {
      await ref.read(pushServiceProvider).saveProfileSettings(value);
      ref.invalidate(profileSettingsProvider);
    } catch (_) {
      if (mounted) {
        setState(() => message = 'No se pudieron guardar los cambios.');
      }
    }
  }

  Future<void> saveName() async {
    final name = displayName.text.trim();
    final next = settings.copyWith(
      displayName: name.isEmpty ? null : name,
      clearDisplayName: name.isEmpty,
    );
    await saveSettings(next);
    if (mounted) setState(() => message = 'Perfil actualizado.');
  }

  String initials(PushService service) {
    final source = settings.displayName?.trim().isNotEmpty == true
        ? settings.displayName!
        : service.email ?? 'F';
    final words = source
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (words.isEmpty) return 'F';
    if (words.length == 1) return words.first.substring(0, 1).toUpperCase();
    return '${words.first.substring(0, 1)}${words.last.substring(0, 1)}'
        .toUpperCase();
  }

  Widget notificationSwitch({
    required String title,
    required IconData icon,
    required bool value,
    required UserProfileSettings Function(bool) change,
  }) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    secondary: Icon(icon),
    title: Text(title),
    value: value,
    onChanged: (next) => saveSettings(change(next)),
  );

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(pushServiceProvider);
    final follows = ref.watch(followsProvider).asData?.value ?? const <String>{};

    final teamCount = follows.where((value) => value.startsWith('team:')).length;
    final competitionCount = follows
        .where((value) => value.startsWith('competition:'))
        .length;
    final playerCount = follows
        .where((value) => value.startsWith('player:'))
        .length;

    return Scaffold(
      appBar: AppBar(title: const Text('Perfil')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 28,
                    child: Text(
                      initials(service),
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          settings.displayName?.trim().isNotEmpty == true
                              ? settings.displayName!
                              : 'Tu perfil',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (service.email != null)
                          Text(
                            service.email!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.star_outline),
            title: const Text('Mis favoritos'),
            subtitle: Text(
              '$teamCount equipos · $competitionCount ligas · $playerCount jugadores',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/favorites'),
          ),
          const SizedBox(height: 8),
          const CountryPreferencePanel(),
          const SizedBox(height: 20),
          const Text(
            'Preferencias',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: settings.hourFormat,
            decoration: const InputDecoration(labelText: 'Formato de hora'),
            items: const [
              DropdownMenuItem(
                value: 'system',
                child: Text('Según el dispositivo'),
              ),
              DropdownMenuItem(value: '12h', child: Text('12 horas')),
              DropdownMenuItem(value: '24h', child: Text('24 horas')),
            ],
            onChanged: loaded
                ? (value) {
                    if (value != null) {
                      saveSettings(settings.copyWith(hourFormat: value));
                    }
                  }
                : null,
          ),
          const SizedBox(height: 20),
          const Text(
            'Cuenta',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          const SizedBox(height: 10),
          if (!service.accountConfigured)
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.cloud_off_outlined),
              title: Text('Inicio de sesión no disponible'),
            )
          else if (!service.authenticated) ...[
            TextField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(labelText: 'Correo'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: password,
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              decoration: const InputDecoration(labelText: 'Contraseña'),
            ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: busy
                  ? null
                  : () => action(
                      () => service.signIn(email.text, password.text),
                      'Sesión iniciada.',
                    ),
              child: const Text('Iniciar sesión'),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () => action(
                      () => service.signUp(email.text, password.text),
                      'Cuenta creada. Revisa tu correo para confirmarla.',
                    ),
              child: const Text('Crear cuenta'),
            ),
          ] else ...[
            TextField(
              controller: displayName,
              enabled: !busy,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: 'Nombre',
                counterText: '',
              ),
              onSubmitted: (_) => saveName(),
            ),
            const SizedBox(height: 10),
            FilledButton.tonal(
              onPressed: busy ? null : saveName,
              child: const Text('Guardar nombre'),
            ),
          ],
          const SizedBox(height: 22),
          const Text(
            'Notificaciones',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          if (loaded) ...[
            notificationSwitch(
              title: 'Inicio de partido',
              icon: Icons.play_circle_outline,
              value: settings.notifyKickoff,
              change: (value) => settings.copyWith(notifyKickoff: value),
            ),
            notificationSwitch(
              title: 'Goles',
              icon: Icons.sports_soccer,
              value: settings.notifyGoals,
              change: (value) => settings.copyWith(notifyGoals: value),
            ),
            notificationSwitch(
              title: 'Resultado final',
              icon: Icons.flag_outlined,
              value: settings.notifyFinal,
              change: (value) => settings.copyWith(notifyFinal: value),
            ),
            notificationSwitch(
              title: 'Tarjetas',
              icon: Icons.style_outlined,
              value: settings.notifyCards,
              change: (value) => settings.copyWith(notifyCards: value),
            ),
            notificationSwitch(
              title: 'Alineaciones',
              icon: Icons.groups_outlined,
              value: settings.notifyLineups,
              change: (value) => settings.copyWith(notifyLineups: value),
            ),
            notificationSwitch(
              title: 'Noticias',
              icon: Icons.article_outlined,
              value: settings.notifyNews,
              change: (value) => settings.copyWith(notifyNews: value),
            ),
            notificationSwitch(
              title: 'Transferencias',
              icon: Icons.swap_horiz,
              value: settings.notifyTransfers,
              change: (value) => settings.copyWith(notifyTransfers: value),
            ),
          ],
          if (service.authenticated && PushService.configured) ...[
            const SizedBox(height: 6),
            FilledButton.tonalIcon(
              onPressed: busy
                  ? null
                  : service.enabled
                  ? () => action(
                      service.disable,
                      'Notificaciones desactivadas.',
                    )
                  : () => action(
                      service.enable,
                      'Notificaciones activadas.',
                    ),
              icon: Icon(
                service.enabled
                    ? Icons.notifications_off_outlined
                    : Icons.notifications_active_outlined,
              ),
              label: Text(
                service.enabled
                    ? 'Desactivar avisos en este dispositivo'
                    : 'Activar avisos en este dispositivo',
              ),
            ),
          ],
          if (service.authenticated) ...[
            const SizedBox(height: 22),
            TextButton.icon(
              onPressed: busy
                  ? null
                  : () => action(service.signOut, 'Sesión cerrada.'),
              icon: const Icon(Icons.logout),
              label: const Text('Cerrar sesión'),
            ),
          ],
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(message!),
            ),
        ],
      ),
    );
  }
}

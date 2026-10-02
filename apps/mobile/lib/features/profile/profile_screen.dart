import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth_errors.dart';
import '../../core/providers.dart';
import '../../core/push.dart';
import '../../core/push_messages.dart';
import 'competition_order_preferences.dart';
import 'notification_options.dart';

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
  String? emailError;
  String? passwordError;

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

  Future<void> action(
    Future<void> Function() work,
    String success, {
    String Function()? successFor,
  }) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await work();
      await _load();
      if (mounted) setState(() => message = successFor?.call() ?? success);
    } catch (error) {
      if (mounted) setState(() => message = authErrorMessage(error));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Validates the form locally before any request is sent.
  bool _validCredentials({required bool signUp}) {
    final nextEmail = validateEmail(email.text);
    final nextPassword = validatePassword(password.text, signUp: signUp);
    setState(() {
      emailError = nextEmail;
      passwordError = nextPassword;
      message = null;
    });
    return nextEmail == null && nextPassword == null;
  }

  Future<void> signIn(PushService service) async {
    if (!_validCredentials(signUp: false)) return;
    await action(() async {
      await service.signIn(email.text, password.text);
      password.clear();
    }, 'Sesión iniciada.');
    await _offerNotifications(service);
  }

  /// After sign-in: offer push once (only when push is configured).
  Future<void> _offerNotifications(PushService service) async {
    if (!mounted || !service.authenticated) return;
    await maybeOfferNotifications(context, service);
    if (mounted) setState(() {});
  }

  Future<void> signUp(PushService service) async {
    if (!_validCredentials(signUp: true)) return;
    await action(
      () async {
        await service.signUp(email.text, password.text);
        password.clear();
      },
      'Cuenta creada. Revisa tu correo para confirmarla.',
      successFor: () => service.authenticated
          ? 'Cuenta creada.'
          : 'Cuenta creada. Revisa tu correo para confirmarla.',
    );
    await _offerNotifications(service);
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

  Future<void> confirmAccountDeletion(PushService service) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar cuenta'),
        content: const Text(
          'Se eliminarán tu perfil, favoritos sincronizados, preferencias y avisos asociados. Esta acción no se puede deshacer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Eliminar definitivamente'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await action(() async {
        await service.deleteAccount();
        ref.invalidate(profileSettingsProvider);
      }, 'Cuenta eliminada.');
    }
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
    final follows =
        ref.watch(followsProvider).asData?.value ?? const <String>{};

    final teamCount = follows
        .where((value) => value.startsWith('team:'))
        .length;
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
              favoritesSummary(
                teams: teamCount,
                competitions: competitionCount,
                players: playerCount,
              ),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/favorites'),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.tune),
            title: const Text('Personalizar FutBeat'),
            subtitle: const Text('País, favoritos y alertas'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/onboarding?reentry=1'),
          ),
          const SizedBox(height: 8),
          const SizedBox(height: 12),
          const CompetitionOrderPanel(),
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
            'Cuenta y seguridad',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          const SizedBox(height: 10),
          if (!service.authenticated) const _GuestCard(),
          if (!service.accountConfigured)
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.cloud_off_outlined),
              title: Text('Inicio de sesión no disponible'),
            )
          else if (!service.authenticated) ...[
            if (service.pendingConfirmationEmail != null)
              Card(
                color: Theme.of(context).colorScheme.secondaryContainer,
                child: ListTile(
                  leading: const Icon(Icons.mark_email_unread_outlined),
                  title: const Text('Confirma tu correo'),
                  subtitle: Text(service.pendingConfirmationEmail!),
                  trailing: TextButton(
                    onPressed: busy
                        ? null
                        : () => action(
                            service.resendEmailConfirmation,
                            'Correo de confirmación reenviado.',
                          ),
                    child: const Text('Reenviar correo'),
                  ),
                ),
              ),
            TextField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: InputDecoration(
                labelText: 'Correo',
                errorText: emailError,
              ),
              onChanged: (_) {
                if (emailError != null) setState(() => emailError = null);
              },
            ),
            const SizedBox(height: 10),
            TextField(
              controller: password,
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              decoration: InputDecoration(
                labelText: 'Contraseña',
                helperText: 'Mínimo 8 caracteres para crear cuenta.',
                errorText: passwordError,
              ),
              onChanged: (_) {
                if (passwordError != null) {
                  setState(() => passwordError = null);
                }
              },
            ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: busy ? null : () => signIn(service),
              child: const Text('Iniciar sesión'),
            ),
            TextButton(
              onPressed: busy ? null : () => signUp(service),
              child: const Text('Crear cuenta'),
            ),
          ] else ...[
            Card(
              color: service.emailVerified == false
                  ? Theme.of(context).colorScheme.secondaryContainer
                  : null,
              child: ListTile(
                leading: Icon(
                  service.emailVerified == false
                      ? Icons.mark_email_unread_outlined
                      : Icons.verified_user_outlined,
                ),
                title: Text(service.email ?? 'Sesión iniciada'),
                subtitle: switch (service.emailVerified) {
                  true => const Text('Correo verificado'),
                  false => const Text('Confirma tu correo'),
                  null => null,
                },
                trailing: service.emailVerified == false
                    ? TextButton(
                        onPressed: busy
                            ? null
                            : () => action(
                                service.resendEmailConfirmation,
                                'Correo de confirmación reenviado.',
                              ),
                        child: const Text('Reenviar correo'),
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 10),
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
            for (final option in notificationOptions)
              notificationSwitch(
                title: option.title,
                icon: option.icon,
                value: option.value(settings),
                change: (value) => option.update(settings, value),
              ),
          ],
          if (service.authenticated && PushService.configured) ...[
            const SizedBox(height: 6),
            FilledButton.tonalIcon(
              onPressed: busy
                  ? null
                  : service.enabled
                  ? () =>
                        action(service.disable, 'Notificaciones desactivadas.')
                  : () => action(service.enable, 'Notificaciones activadas.'),
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
            const Text(
              'Cuenta y privacidad',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 6),
            TextButton.icon(
              onPressed: busy
                  ? null
                  : () => action(service.signOut, 'Sesión cerrada.'),
              icon: const Icon(Icons.logout),
              label: const Text('Cerrar sesión'),
            ),
            TextButton.icon(
              onPressed: busy ? null : () => confirmAccountDeletion(service),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              icon: const Icon(Icons.delete_forever_outlined),
              label: const Text('Eliminar cuenta'),
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

class _GuestCard extends StatelessWidget {
  const _GuestCard();

  @override
  Widget build(BuildContext context) => const Card(
    child: ListTile(
      leading: Icon(Icons.person_outline),
      title: Text('Invitado'),
      subtitle: Text('Tus favoritos se guardan en este dispositivo.'),
    ),
  );
}

/// "1 equipo · 2 ligas · 0 jugadores": Spanish singular only for exactly one.
String favoritesSummary({
  required int teams,
  required int competitions,
  required int players,
}) {
  String count(int n, String one, String many) => '$n ${n == 1 ? one : many}';
  return [
    count(teams, 'equipo', 'equipos'),
    count(competitions, 'liga', 'ligas'),
    count(players, 'jugador', 'jugadores'),
  ].join(' · ');
}

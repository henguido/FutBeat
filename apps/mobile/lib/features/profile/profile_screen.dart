import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/entitlements.dart';
import '../../core/providers.dart';
import '../../core/push.dart';
import '../auth/auth_sheet.dart';
import 'notification_options.dart';
import 'profile_section.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  UserProfileSettings settings = const UserProfileSettings();
  bool loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final service = ref.read(pushServiceProvider);
    await service.restore();
    final value = await service.loadProfileSettings();
    if (!mounted) return;
    setState(() {
      settings = value;
      loaded = true;
    });
  }

  Future<void> _openAuth(AuthMode mode) async {
    await showAuthSheet(context, mode);
    await _load();
  }

  String _initials(PushService service) {
    final source = settings.displayName?.trim().isNotEmpty == true
        ? settings.displayName!
        : service.email ?? 'F';
    final words = source.trim().split(RegExp(r'\s+'));
    return words.length > 1
        ? '${words.first[0]}${words.last[0]}'.toUpperCase()
        : words.first[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(pushServiceProvider);
    final plan = ref.watch(entitlementsProvider);
    final follows =
        ref.watch(followsProvider).asData?.value ?? const <String>{};
    int count(String type) =>
        follows.where((v) => v.startsWith('$type:')).length;
    final summary = favoritesSummary(
      teams: count('team'),
      competitions: count('competition'),
      players: count('player'),
    );
    final provider = authProviderLabel(service.authProvider) ?? 'Correo';
    return Scaffold(
      appBar: AppBar(title: const Text('Perfil')),
      body: ListView(
        key: const ValueKey('profile-root'),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: [
          _ProfileHeader(
            initials: _initials(service),
            name: settings.displayName,
            service: service,
            provider: provider,
            premium: plan.isPremium,
            onLogin: () => _openAuth(AuthMode.login),
            onSignup: () => _openAuth(AuthMode.signup),
            onResend: service.resendEmailConfirmation,
          ),
          ProfileSection(
            title: 'Accesos rápidos',
            children: [
              ProfileDestinationTile(
                icon: Icons.star_outline,
                title: 'Mis favoritos',
                subtitle: summary,
                onTap: () => context.go('/favorites'),
              ),
              ProfileDestinationTile(
                icon: Icons.workspace_premium_outlined,
                title: plan.isPremium ? 'FutBeat Premium' : 'Premium',
                subtitle: plan.isPremium
                    ? 'Sin anuncios'
                    : 'Disfruta FutBeat sin anuncios',
                onTap: () => context.push('/profile/premium'),
              ),
            ],
          ),
          ProfileSection(
            title: 'Configuración',
            children: [
              ProfileDestinationTile(
                icon: Icons.tune,
                title: 'Personalización',
                subtitle: 'País, favoritos, competiciones y hora',
                onTap: () => context.push('/profile/personalization'),
              ),
              ProfileDestinationTile(
                icon: Icons.notifications_none,
                title: 'Notificaciones',
                subtitle: loaded
                    ? notificationSummary(settings)
                    : 'Cargando preferencias…',
                onTap: () => context.push('/profile/notifications'),
              ),
              ProfileDestinationTile(
                icon: Icons.privacy_tip_outlined,
                title: 'Privacidad y anuncios',
                onTap: () => context.push('/profile/privacy'),
              ),
            ],
          ),
          ProfileSection(
            title: service.authenticated ? 'Cuenta y ayuda' : 'Ayuda',
            children: [
              if (service.authenticated || service.accountConfigured)
                ProfileDestinationTile(
                  icon: Icons.manage_accounts_outlined,
                  title: 'Cuenta y seguridad',
                  subtitle: service.authenticated
                      ? '$provider · ${service.emailVerified == true ? 'Correo verificado' : 'Cuenta conectada'}'
                      : 'Inicia sesión o crea una cuenta',
                  onTap: () => context.push('/profile/account'),
                ),
              ProfileDestinationTile(
                icon: Icons.help_outline,
                title: 'Soporte y legal',
                onTap: () => context.push('/profile/support'),
              ),
              ProfileDestinationTile(
                icon: Icons.info_outline,
                title: 'Acerca de FutBeat',
                onTap: () => context.push('/profile/about'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({
    required this.initials,
    required this.name,
    required this.service,
    required this.provider,
    required this.premium,
    required this.onLogin,
    required this.onSignup,
    required this.onResend,
  });
  final String initials;
  final String? name;
  final PushService service;
  final String provider;
  final bool premium;
  final VoidCallback onLogin;
  final VoidCallback onSignup;
  final Future<void> Function() onResend;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 28,
                child: Text(
                  initials,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name?.trim().isNotEmpty == true ? name! : 'Tu perfil',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      service.authenticated
                          ? service.email ?? 'Cuenta conectada'
                          : 'Invitado',
                    ),
                    if (!service.authenticated)
                      const Text(
                        'Tus favoritos se guardan en este dispositivo.',
                      ),
                    if (service.authenticated)
                      Text(
                        '$provider · ${premium ? 'Premium' : 'Plan Gratis'}',
                      ),
                    if (service.emailVerified == true)
                      const Text('Correo verificado'),
                  ],
                ),
              ),
              if (premium) const Chip(label: Text('PREMIUM')),
            ],
          ),
          if (!service.authenticated && service.accountConfigured) ...[
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('profile-login'),
              onPressed: onLogin,
              child: const Text('Iniciar sesión'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              key: const ValueKey('profile-signup'),
              onPressed: onSignup,
              child: const Text('Crear cuenta'),
            ),
          ],
          if (!service.accountConfigured && !service.authenticated) ...[
            const SizedBox(height: 12),
            const Text('Inicio de sesión no disponible.'),
          ],
          if (service.emailVerified == false) ...[
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.mark_email_unread_outlined),
              title: const Text('Confirma tu correo'),
              trailing: TextButton(
                onPressed: onResend,
                child: const Text('Reenviar correo'),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

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

String notificationSummary(UserProfileSettings settings) {
  final values = notificationOptions
      .where((o) => o.value(settings))
      .map((o) => o.title)
      .toList();
  if (values.isEmpty) return 'Sin alertas seleccionadas';
  final shown = values.take(3).join(', ');
  return values.length > 3 ? '$shown y ${values.length - 3} más' : shown;
}

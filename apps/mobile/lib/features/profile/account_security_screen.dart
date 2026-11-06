import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth_errors.dart';
import '../../core/push.dart';
import '../auth/auth_sheet.dart';
import 'password_reset_sheet.dart';
import 'profile_section.dart';

class AccountSecurityScreen extends ConsumerStatefulWidget {
  const AccountSecurityScreen({super.key});
  @override
  ConsumerState<AccountSecurityScreen> createState() =>
      _AccountSecurityScreenState();
}

class _AccountSecurityScreenState extends ConsumerState<AccountSecurityScreen> {
  final name = TextEditingController();
  UserProfileSettings? settings;
  String? loadedAccountId;
  bool loading = true;
  bool busy = false;
  String? message;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final service = ref.read(pushServiceProvider);
    setState(() {
      loading = true;
      settings = null;
      message = null;
    });
    try {
      await service.restore();
      if (!mounted) return;
      final accountId = service.userId;
      final value = await service.loadProfileSettings();
      if (!mounted) return;
      if (service.userId != accountId) {
        throw StateError('Account changed while loading profile');
      }
      setState(() {
        loadedAccountId = accountId;
        settings = value;
        name.text = value.displayName ?? '';
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => message = 'No pudimos cargar tu perfil. Inténtalo nuevamente.',
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _action(Future<void> Function() work, String success) async {
    if (busy || !mounted) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await work();
      if (mounted) setState(() => message = success);
    } catch (error) {
      if (mounted) setState(() => message = authErrorMessage(error));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _saveName() async {
    final current = settings;
    if (current == null || loading || busy) return;
    final service = ref.read(pushServiceProvider);
    final accountId = loadedAccountId;
    if (accountId == null || service.userId != accountId) {
      setState(
        () => message = 'La cuenta cambió. Vuelve a abrir esta pantalla.',
      );
      return;
    }
    final text = name.text.trim();
    final next = current.copyWith(
      displayName: text.isEmpty ? null : text,
      clearDisplayName: text.isEmpty,
    );
    await _action(() async {
      await service.updateProfileSettings(
        (current) => current.copyWith(
          displayName: text.isEmpty ? null : text,
          clearDisplayName: text.isEmpty,
        ),
        expectedUserId: accountId,
      );
      if (!mounted) return;
      ref.invalidate(profileSettingsProvider);
      settings = next;
    }, 'Perfil actualizado.');
  }

  Future<void> _delete(PushService service, String? accountId) async {
    bool accountChanged() =>
        accountId == null ||
        !identical(ref.read(pushServiceProvider), service) ||
        service.userId != accountId;

    void showAccountChanged() => setState(
      () => message = 'La cuenta cambió. Vuelve a abrir esta pantalla.',
    );

    if (accountChanged()) {
      showAccountChanged();
      return;
    }
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
    if (!mounted || confirmed != true) return;
    if (accountChanged()) {
      showAccountChanged();
      return;
    }
    await _action(service.deleteAccount, 'Cuenta eliminada.');
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(pushServiceProvider);
    final accountId = service.userId;
    final provider = authProviderLabel(service.authProvider) ?? 'Correo';
    final isEmail =
        service.authProvider == null || service.authProvider == 'email';
    return Scaffold(
      appBar: AppBar(title: const Text('Cuenta y seguridad')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (loading) const LinearProgressIndicator(),
          if (!loading && settings == null)
            TextButton(onPressed: _load, child: const Text('Reintentar')),
          if (!service.registered)
            ProfileSection(
              title: 'Tu cuenta',
              children: [
                ListTile(
                  title: Text(
                    service.hasUnconfirmedSignOut
                        ? 'Cierre de sesión no confirmado'
                        : 'Sin sesión iniciada',
                  ),
                  subtitle: Text(
                    service.hasUnconfirmedSignOut
                        ? 'Intenta cerrar la sesión nuevamente antes de cambiar de cuenta.'
                        : 'Inicia sesión para sincronizar tus datos.',
                  ),
                ),
                if (service.hasUnconfirmedSignOut)
                  ListTile(
                    key: const ValueKey('account-logout'),
                    title: const Text('Reintentar cierre de sesión'),
                    trailing: const Icon(Icons.logout),
                    onTap: busy
                        ? null
                        : () => _action(service.signOut, 'Sesión cerrada.'),
                  )
                else ...[
                  ListTile(
                    key: const ValueKey('account-login'),
                    title: const Text('Iniciar sesión'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await showAuthSheet(context, AuthMode.login);
                      await _load();
                    },
                  ),
                  ListTile(
                    key: const ValueKey('account-signup'),
                    title: const Text('Crear cuenta'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await showAuthSheet(context, AuthMode.signup);
                      await _load();
                    },
                  ),
                ],
              ],
            )
          else ...[
            ProfileSection(
              title: 'Cuenta conectada',
              children: [
                ListTile(
                  leading: const Icon(Icons.account_circle_outlined),
                  title: Text(service.email ?? 'Cuenta conectada'),
                  subtitle: Text(
                    '$provider · ${service.emailVerified == true
                        ? 'Verificado'
                        : service.emailVerified == false
                        ? 'Pendiente de verificar'
                        : 'Estado no disponible'}',
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      TextField(
                        key: const ValueKey('account-name'),
                        controller: name,
                        enabled: !busy && !loading && settings != null,
                        maxLength: 80,
                        decoration: const InputDecoration(
                          labelText: 'Nombre',
                          counterText: '',
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.tonal(
                          key: const ValueKey('account-name-save'),
                          onPressed: busy || loading || settings == null
                              ? null
                              : _saveName,
                          child: const Text('Guardar nombre'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            ProfileSection(
              title: 'Seguridad',
              children: [
                if (isEmail)
                  ListTile(
                    key: const ValueKey('account-password-reset'),
                    leading: const Icon(Icons.password_outlined),
                    title: const Text('Cambiar o recuperar contraseña'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => PasswordResetSheet(
                        service: service,
                        initialEmail: service.email ?? '',
                      ),
                    ),
                  )
                else
                  ListTile(
                    leading: const Icon(Icons.password_outlined),
                    title: const Text('Contraseña'),
                    subtitle: Text('Gestionada por $provider'),
                  ),
                ListTile(
                  key: const ValueKey('account-logout'),
                  leading: const Icon(Icons.logout),
                  title: const Text('Cerrar sesión'),
                  onTap: busy
                      ? null
                      : () => _action(service.signOut, 'Sesión cerrada.'),
                ),
              ],
            ),
            ProfileSection(
              title: 'Zona de peligro',
              children: [
                ListTile(
                  key: const ValueKey('account-delete'),
                  leading: Icon(
                    Icons.delete_forever_outlined,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: Text(
                    'Eliminar cuenta',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  subtitle: const Text(
                    'Borra el perfil y los datos asociados de FutBeat.',
                  ),
                  onTap: busy ? null : () => _delete(service, accountId),
                ),
              ],
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

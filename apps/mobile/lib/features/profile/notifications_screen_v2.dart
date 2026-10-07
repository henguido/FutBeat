import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/push.dart';
import '../../core/theme.dart';
import 'notification_options.dart';
import 'profile_section.dart';

class NotificationsScreenV2 extends ConsumerStatefulWidget {
  const NotificationsScreenV2({super.key});

  @override
  ConsumerState<NotificationsScreenV2> createState() =>
      _NotificationsScreenV2State();
}

class _NotificationsScreenV2State extends ConsumerState<NotificationsScreenV2> {
  UserProfileSettings? settings;
  DeviceNotificationPermission permission =
      DeviceNotificationPermission.unknown;
  bool busy = false;
  String? actionError;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final service = ref.read(pushServiceProvider);
    final loaded = await service.loadProfileSettings();
    if (!mounted) return;
    setState(() => settings = loaded);
    final devicePermission = service.pushConfigured
        ? await service.notificationPermission()
        : DeviceNotificationPermission.unknown;
    if (!mounted) return;
    setState(() => permission = devicePermission);
  }

  Future<void> _save(NotificationOption option, bool enabled) async {
    final current = settings;
    if (current == null) return;
    final next = option.update(current, enabled);
    setState(() {
      settings = next;
      actionError = null;
    });
    final service = ref.read(pushServiceProvider);
    try {
      await service.saveProfileSettings(next);
      ref.invalidate(profileSettingsProvider);
    } catch (_) {
      final local = await service.loadProfileSettings();
      if (!mounted) return;
      final savedLocally = option.value(local) == enabled;
      setState(() {
        settings = savedLocally ? local : current;
        actionError = savedLocally
            ? 'Guardado en este dispositivo. Se sincronizará cuando haya conexión.'
            : 'No pudimos guardar este cambio. Inténtalo nuevamente.';
      });
    }
  }

  Future<void> _enable() async {
    setState(() {
      busy = true;
      actionError = null;
    });
    final service = ref.read(pushServiceProvider);
    try {
      await service.enable();
    } catch (_) {
      if (mounted) {
        setState(() {
          actionError = 'No pudimos activar las notificaciones. Revisa el permiso del sistema.';
        });
      }
    } finally {
      final current = service.pushConfigured
          ? await service.notificationPermission()
          : DeviceNotificationPermission.unknown;
      if (mounted) {
        setState(() {
          permission = current;
          busy = false;
        });
      }
    }
  }

  Future<void> _disable() async {
    setState(() {
      busy = true;
      actionError = null;
    });
    try {
      await ref.read(pushServiceProvider).disable();
    } catch (_) {
      if (mounted) {
        setState(() {
          actionError = 'No pudimos desactivar las notificaciones ahora.';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(pushServiceProvider);
    final value = settings;
    final effectivePermission = _effectivePermission(service);
    return Scaffold(
      appBar: AppBar(title: const Text('Notificaciones')),
      body: value == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                _deviceSection(service),
                if (effectivePermission != DeviceNotificationPermission.allowed)
                  const _PreferenceAvailabilityNotice(),
                if (actionError case final message?)
                  _InlineMessage(message: message),
                const _FollowContext(),
                for (final group in NotificationOptionGroup.values)
                  _options(group, value),
              ],
            ),
    );
  }

  Widget _deviceSection(PushService service) {
    final effectivePermission = _effectivePermission(service);
    final permissionCopy = switch (effectivePermission) {
      DeviceNotificationPermission.allowed => (
        'Permitidas',
        'Android puede mostrar alertas de FutBeat.',
        Icons.check_circle_outline,
        lime,
      ),
      DeviceNotificationPermission.denied => (
        'Denegadas',
        'Actívalas desde los ajustes del sistema para poder recibirlas.',
        Icons.block_outlined,
        Colors.orangeAccent,
      ),
      DeviceNotificationPermission.notRequested => (
        'No solicitadas',
        'FutBeat solo pedirá permiso cuando pulses Activar notificaciones.',
        Icons.notifications_none_outlined,
        muted,
      ),
      DeviceNotificationPermission.unknown => (
        'Estado desconocido',
        'No pudimos comprobar el permiso de este dispositivo.',
        Icons.help_outline,
        muted,
      ),
    };
    final canEnable =
        service.authenticated &&
        service.pushConfigured &&
        effectivePermission != DeviceNotificationPermission.denied;
    return ProfileSection(
      title: 'En este dispositivo',
      children: [
        ListTile(
          key: const ValueKey('notification-permission-status'),
          leading: Icon(permissionCopy.$3, color: permissionCopy.$4),
          title: Text(
            permissionCopy.$1,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          subtitle: Text(permissionCopy.$2),
        ),
        ListTile(
          key: const ValueKey('futbeat-notifications-control'),
          leading: Icon(
            service.enabled
                ? Icons.notifications_active_outlined
                : Icons.notifications_off_outlined,
          ),
          title: const Text('Notificaciones de FutBeat'),
          subtitle: Text(
            service.enabled
                ? 'Activas en este dispositivo.'
                : !service.authenticated
                ? 'Inicia sesión para activarlas en este dispositivo.'
                : !service.pushConfigured
                ? 'No están disponibles en esta versión.'
                : effectivePermission == DeviceNotificationPermission.denied
                ? 'El permiso está bloqueado en los ajustes del sistema.'
                : 'Desactivadas en este dispositivo.',
          ),
          trailing: service.enabled
              ? TextButton(
                  key: const ValueKey('disable-notifications'),
                  onPressed: busy ? null : _disable,
                  child: const Text('Desactivar'),
                )
              : canEnable
              ? FilledButton(
                  key: const ValueKey('enable-notifications'),
                  onPressed: busy ? null : _enable,
                  child: const Text('Activar notificaciones'),
                )
              : null,
        ),
      ],
    );
  }

  DeviceNotificationPermission _effectivePermission(PushService service) =>
      permission == DeviceNotificationPermission.unknown && service.enabled
      ? DeviceNotificationPermission.allowed
      : permission;

  Widget _options(NotificationOptionGroup group, UserProfileSettings value) {
    final options = notificationOptions
        .where((option) => option.group == group)
        .toList(growable: false);
    final title = switch (group) {
      NotificationOptionGroup.matches => 'Partidos',
      NotificationOptionGroup.followedEntities => 'Equipos y jugadores',
      NotificationOptionGroup.other => 'Otros',
    };
    return ProfileSection(
      title: title,
      children: [
        for (final option in options)
          SwitchListTile(
            key: ValueKey('notification-${option.serverKey}'),
            secondary: Icon(option.icon),
            title: Text(option.title),
            value: option.value(value),
            onChanged: (next) => _save(option, next),
          ),
      ],
    );
  }
}

class _PreferenceAvailabilityNotice extends StatelessWidget {
  const _PreferenceAvailabilityNotice();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(top: 12),
    child: Text(
      'Puedes preparar tus preferencias ahora. Se aplicarán cuando las notificaciones estén permitidas.',
      style: TextStyle(color: muted, height: 1.35),
    ),
  );
}

class _FollowContext extends StatelessWidget {
  const _FollowContext();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(top: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.star_outline_rounded, color: lime, size: 18),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            'Recibirás estas alertas para los equipos y jugadores que sigues.',
            style: TextStyle(color: muted, height: 1.35),
          ),
        ),
      ],
    ),
  );
}

class _InlineMessage extends StatelessWidget {
  const _InlineMessage({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Material(
      color: Colors.orange.withValues(alpha: .10),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(message, style: const TextStyle(height: 1.35)),
      ),
    ),
  );
}

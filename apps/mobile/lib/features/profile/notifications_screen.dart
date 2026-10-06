import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/push.dart';
import 'notification_options.dart';
import 'profile_section.dart';

class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});
  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  UserProfileSettings? settings;
  bool busy = false;
  bool permissionDenied = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final value = await ref.read(pushServiceProvider).loadProfileSettings();
    if (mounted) setState(() => settings = value);
  }

  Future<void> _save(NotificationOption option, bool value) async {
    final current = settings;
    if (current == null) return;
    final next = option.update(current, value);
    setState(() => settings = next);
    try {
      await ref.read(pushServiceProvider).saveProfileSettings(next);
      ref.invalidate(profileSettingsProvider);
    } catch (_) {
      if (mounted) setState(() => settings = current);
    }
  }

  Future<void> _enable() async {
    setState(() {
      busy = true;
      permissionDenied = false;
    });
    try {
      await ref.read(pushServiceProvider).enable();
    } catch (_) {
      permissionDenied = true;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(pushServiceProvider);
    final value = settings;
    final status = service.enabled
        ? 'Permitido'
        : permissionDenied
        ? 'Denegado'
        : 'No solicitado';
    return Scaffold(
      appBar: AppBar(title: const Text('Notificaciones')),
      body: value == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                ProfileSection(
                  title: 'En este dispositivo',
                  children: [
                    ListTile(
                      key: const ValueKey('notification-permission-status'),
                      leading: const Icon(Icons.phone_android),
                      title: const Text('Permiso de Android'),
                      subtitle: Text(status),
                      trailing:
                          service.enabled ||
                              !service.authenticated ||
                              !PushService.configured
                          ? null
                          : FilledButton(
                              key: const ValueKey('enable-notifications'),
                              onPressed: busy ? null : _enable,
                              child: const Text('Activar'),
                            ),
                    ),
                  ],
                ),
                _options('Partidos', notificationOptions.sublist(0, 5), value),
                _options(
                  'Jugadores favoritos',
                  notificationOptions.sublist(5, 9),
                  value,
                ),
                _options('Contenido', notificationOptions.sublist(9), value),
              ],
            ),
    );
  }

  Widget _options(
    String title,
    List<NotificationOption> options,
    UserProfileSettings value,
  ) => ProfileSection(
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

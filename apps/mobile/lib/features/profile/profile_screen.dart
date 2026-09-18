import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/push.dart';
import 'country_preferences.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});
  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final email = TextEditingController(), password = TextEditingController();
  bool busy = false;
  String? message;
  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> action(Future<void> Function() work, String success) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await work();
      if (mounted) setState(() => message = success);
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'No se pudo completar. Revisa tu conexión, acceso y permisos.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(pushServiceProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Perfil')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const CountryPreferencePanel(),
          const SizedBox(height: 20),
          const Text(
            'Cuenta y notificaciones',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          if (!PushService.configured)
            const Text(
              'Las notificaciones todavía no están disponibles. Puedes seguir consultando los partidos en vivo.',
            )
          else ...[
            const Text('Recibe avisos de los equipos y partidos que sigues.'),
            if (!service.authenticated) ...[
              TextField(
                controller: email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Correo'),
              ),
              TextField(
                controller: password,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Contraseña'),
              ),
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
                        'Revisa tu correo para confirmar la cuenta y luego inicia sesión.',
                      ),
                child: const Text('Crear cuenta'),
              ),
            ] else ...[
              FilledButton(
                onPressed: busy
                    ? null
                    : () => action(service.enable, 'Notificaciones activadas.'),
                child: const Text('Activar notificaciones'),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () => action(
                        service.disable,
                        'Notificaciones desactivadas.',
                      ),
                child: const Text('Desactivar notificaciones'),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () => action(service.signOut, 'Sesión cerrada.'),
                child: const Text('Cerrar sesión'),
              ),
            ],
          ],
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(message!),
            ),
        ],
      ),
    );
  }
}

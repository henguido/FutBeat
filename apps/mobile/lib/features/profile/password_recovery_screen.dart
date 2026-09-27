import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/push.dart';

class PasswordRecoveryScreen extends ConsumerStatefulWidget {
  const PasswordRecoveryScreen({super.key, required this.uri});

  final Uri uri;

  @override
  ConsumerState<PasswordRecoveryScreen> createState() =>
      _PasswordRecoveryScreenState();
}

class _PasswordRecoveryScreenState
    extends ConsumerState<PasswordRecoveryScreen> {
  final password = TextEditingController();
  final confirmation = TextEditingController();
  bool validLink = true;
  bool busy = false;
  String? message;

  @override
  void initState() {
    super.initState();
    try {
      ref.read(pushServiceProvider).beginPasswordRecovery(widget.uri);
    } catch (_) {
      validLink = false;
    }
  }

  @override
  void dispose() {
    password.dispose();
    confirmation.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (password.text.length < 8) {
      setState(() => message = 'Usa al menos 8 caracteres.');
      return;
    }
    if (password.text != confirmation.text) {
      setState(() => message = 'Las contraseñas no coinciden.');
      return;
    }
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await ref
          .read(pushServiceProvider)
          .updateRecoveredPassword(password.text);
      if (!mounted) return;
      password.clear();
      confirmation.clear();
      setState(
        () => message = 'Contraseña actualizada. Ya puedes iniciar sesión.',
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => message = 'No se pudo actualizar. Solicita un enlace nuevo.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Nueva contraseña')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        if (!validLink) ...[
          const Text('Este enlace no es válido o está incompleto.'),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => context.go('/profile'),
            child: const Text('Volver a Perfil'),
          ),
        ] else ...[
          const Text('Define una contraseña nueva para tu cuenta.'),
          const SizedBox(height: 16),
          TextField(
            controller: password,
            obscureText: true,
            enabled: !busy,
            decoration: const InputDecoration(labelText: 'Nueva contraseña'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: confirmation,
            obscureText: true,
            enabled: !busy,
            decoration: const InputDecoration(
              labelText: 'Confirmar contraseña',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: busy ? null : submit,
            child: const Text('Actualizar contraseña'),
          ),
          if (message != null) ...[const SizedBox(height: 12), Text(message!)],
        ],
      ],
    ),
  );
}

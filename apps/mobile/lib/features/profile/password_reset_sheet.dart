import 'package:flutter/material.dart';

import '../../core/auth_errors.dart';
import '../../core/push.dart';
import '../../core/theme.dart';

/// "¿Olvidaste tu contraseña?": the email gets a link that opens FutBeat on
/// the "Nueva contraseña" screen ([NewPasswordScreen]). No code to type.
class PasswordResetSheet extends StatefulWidget {
  const PasswordResetSheet({
    required this.service,
    this.initialEmail = '',
    super.key,
  });

  final PushService service;
  final String initialEmail;

  @override
  State<PasswordResetSheet> createState() => _PasswordResetSheetState();
}

class _PasswordResetSheetState extends State<PasswordResetSheet> {
  late final email = TextEditingController(text: widget.initialEmail);
  bool linkSent = false;
  bool busy = false;
  String? message;
  String? emailError;

  @override
  void dispose() {
    email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final error = validateEmail(email.text);
    setState(() {
      emailError = error;
      message = null;
    });
    if (error != null) return;
    setState(() => busy = true);
    try {
      await widget.service.requestPasswordReset(email.text);
      if (mounted) {
        setState(() {
          message = linkSent ? 'Enlace reenviado.' : null;
          linkSent = true;
        });
      }
    } catch (error) {
      if (mounted) setState(() => message = authErrorMessage(error));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            linkSent ? 'Revisa tu correo' : 'Recuperar contraseña',
            key: const ValueKey('reset-title'),
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 20),
          ),
          const SizedBox(height: 8),
          if (linkSent) ...[
            const Text(
              'Te enviamos un enlace para cambiar tu contraseña.',
              style: TextStyle(color: muted),
            ),
            Text(
              email.text.trim(),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text(
              'Ábrelo en este teléfono para elegir una nueva.',
              style: TextStyle(color: muted),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 52,
              child: FilledButton(
                key: const ValueKey('reset-back'),
                onPressed: busy ? null : () => Navigator.pop(context, false),
                child: const Text('Volver a iniciar sesión'),
              ),
            ),
            TextButton(
              key: const ValueKey('reset-resend'),
              onPressed: busy ? null : _send,
              child: const Text('Reenviar enlace'),
            ),
          ] else ...[
            TextField(
              key: const ValueKey('reset-email'),
              controller: email,
              enabled: !busy,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                labelText: 'Correo',
                errorText: emailError,
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 52,
              child: FilledButton(
                key: const ValueKey('reset-send'),
                onPressed: busy ? null : _send,
                child: const Text('Enviar enlace'),
              ),
            ),
          ],
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                message!,
                key: const ValueKey('reset-message'),
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    ),
  );
}

/// Opened by a redeemed password-reset link: choose the new password. The
/// account is signed in only once it is saved; leaving drops the recovery.
class NewPasswordScreen extends StatefulWidget {
  const NewPasswordScreen({required this.service, super.key});

  final PushService service;

  @override
  State<NewPasswordScreen> createState() => _NewPasswordScreenState();
}

class _NewPasswordScreenState extends State<NewPasswordScreen> {
  final password = TextEditingController();
  final confirm = TextEditingController();
  bool obscure = true;
  bool busy = false;
  String? passwordError;
  String? confirmError;
  String? message;

  @override
  void dispose() {
    password.dispose();
    confirm.dispose();
    if (widget.service.passwordRecoveryPending) {
      widget.service.cancelPasswordRecovery();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final nextPassword = validatePassword(password.text, signUp: true);
    final nextConfirm = confirm.text == password.text
        ? null
        : 'Las contraseñas no coinciden.';
    setState(() {
      passwordError = nextPassword;
      confirmError = nextConfirm;
      message = null;
    });
    if (nextPassword != null || nextConfirm != null) return;
    setState(() => busy = true);
    try {
      await widget.service.completePasswordRecovery(password.text);
      password.clear();
      confirm.clear();
      if (mounted) Navigator.pop(context, true);
    } on RecoveryLinkInvalid {
      if (mounted) {
        setState(() => message = 'El enlace ya no es válido. Pide uno nuevo.');
      }
    } catch (error) {
      if (mounted) setState(() => message = authErrorMessage(error));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget field(
      String key,
      TextEditingController controller,
      String label,
      String? error, {
      String? helper,
    }) => TextField(
      key: ValueKey(key),
      controller: controller,
      enabled: !busy,
      obscureText: obscure,
      autofillHints: const [AutofillHints.newPassword],
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        errorText: error,
      ),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Nueva contraseña')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Elige una nueva contraseña para tu cuenta de FutBeat.',
              style: TextStyle(color: muted),
            ),
            const SizedBox(height: 16),
            field(
              'new-password',
              password,
              'Nueva contraseña',
              passwordError,
              helper: 'Mínimo 8 caracteres.',
            ),
            const SizedBox(height: 10),
            field(
              'confirm-password',
              confirm,
              'Confirmar contraseña',
              confirmError,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => obscure = !obscure),
                icon: Icon(
                  obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                label: Text(obscure ? 'Mostrar' : 'Ocultar'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 52,
              child: FilledButton(
                key: const ValueKey('new-password-save'),
                onPressed: busy ? null : _save,
                child: busy
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Cambiar contraseña'),
              ),
            ),
            if (message != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  message!,
                  key: const ValueKey('new-password-message'),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

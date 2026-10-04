import 'package:flutter/material.dart';

import '../../core/auth_errors.dart';
import '../../core/push.dart';

/// "¿Olvidaste tu contraseña?": email → code from the email + new password.
/// Pops `true` once the password changed (the account is then signed in).
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
  final code = TextEditingController();
  final password = TextEditingController();
  bool codeSent = false;
  bool busy = false;
  String? message;
  String? emailError;
  String? codeError;
  String? passwordError;

  @override
  void dispose() {
    email.dispose();
    code.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() work) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await work();
    } catch (error) {
      if (mounted) setState(() => message = authErrorMessage(error));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _sendCode() async {
    final error = validateEmail(email.text);
    setState(() => emailError = error);
    if (error != null) return;
    await _run(() async {
      await widget.service.requestPasswordReset(email.text);
      if (mounted) {
        setState(() {
          codeSent = true;
          message = 'Te enviamos un código a tu correo.';
        });
      }
    });
  }

  Future<void> _reset() async {
    final digits = code.text.trim();
    final nextCodeError = RegExp(r'^\d{6,10}$').hasMatch(digits)
        ? null
        : 'Escribe el código del correo.';
    final nextPasswordError = validatePassword(password.text, signUp: true);
    setState(() {
      codeError = nextCodeError;
      passwordError = nextPasswordError;
    });
    if (nextCodeError != null || nextPasswordError != null) return;
    await _run(() async {
      await widget.service.resetPassword(email.text, digits, password.text);
      if (mounted) Navigator.of(context).pop(true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
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
            const Text(
              'Recuperar contraseña',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('reset-email'),
              controller: email,
              enabled: !codeSent,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: InputDecoration(
                labelText: 'Correo',
                errorText: emailError,
              ),
            ),
            if (codeSent) ...[
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('reset-code'),
                controller: code,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                decoration: InputDecoration(
                  labelText: 'Código',
                  errorText: codeError,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('reset-password'),
                controller: password,
                obscureText: true,
                autofillHints: const [AutofillHints.newPassword],
                decoration: InputDecoration(
                  labelText: 'Nueva contraseña',
                  helperText: 'Mínimo 8 caracteres.',
                  errorText: passwordError,
                ),
              ),
            ],
            if (message != null) ...[
              const SizedBox(height: 10),
              Text(message!, key: const ValueKey('reset-message')),
            ],
            const SizedBox(height: 12),
            FilledButton(
              onPressed: busy ? null : (codeSent ? _reset : _sendCode),
              child: Text(codeSent ? 'Cambiar contraseña' : 'Enviar código'),
            ),
            if (codeSent)
              TextButton(
                onPressed: busy ? null : _sendCode,
                child: const Text('Reenviar código'),
              ),
          ],
        ),
      ),
    );
  }
}

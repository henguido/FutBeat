import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth_errors.dart';
import '../../core/push.dart';
import '../../core/theme.dart';
import '../profile/password_reset_sheet.dart';

enum AuthMode { login, signup }

/// Social providers this build can offer (see [PushService.oauthProviders]).
final oauthProvidersProvider = FutureProvider<Set<OAuthProvider>>(
  (ref) => ref.watch(pushServiceProvider).oauthProviders(),
);

/// Sign in / create an account without leaving the current screen. Completes
/// with `true` once there is a valid session; the caller stays where it was.
Future<bool> showAuthSheet(BuildContext context, AuthMode mode) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: const Color(0xFF0F1519),
    builder: (_) => AuthSheet(mode: mode),
  );
  return result == true;
}

class AuthSheet extends ConsumerStatefulWidget {
  const AuthSheet({required this.mode, super.key});

  final AuthMode mode;

  @override
  ConsumerState<AuthSheet> createState() => _AuthSheetState();
}

class _AuthSheetState extends ConsumerState<AuthSheet> {
  late AuthMode mode = widget.mode;
  final email = TextEditingController();
  final password = TextEditingController();
  bool obscure = true;
  bool busy = false;
  String? message;
  String? emailError;
  String? passwordError;

  /// The address waiting for its confirmation email (after sign-up, or a
  /// sign-in refused because it is not confirmed yet).
  String? confirmationEmail;

  bool get signup => mode == AuthMode.signup;

  @override
  void dispose() {
    email.dispose();
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
    } on OAuthCancelled {
      // Closing the provider page leaves everything as it was.
    } on OAuthFailed {
      if (mounted) setState(() => message = 'No se pudo iniciar sesión.');
    } catch (error) {
      final text = authErrorMessage(error);
      if (mounted) {
        setState(() {
          message = text;
          if (text == 'Confirma tu correo para iniciar sesión.') {
            confirmationEmail = email.text.trim();
          }
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _closeIfSignedIn() {
    if (mounted && ref.read(pushServiceProvider).authenticated) {
      Navigator.pop(context, true);
    }
  }

  Future<void> _oauth(OAuthProvider provider) => _run(() async {
    await ref.read(pushServiceProvider).signInWithOAuth(provider);
    _closeIfSignedIn();
  });

  Future<void> _submit() async {
    final nextEmail = validateEmail(email.text);
    final nextPassword = validatePassword(password.text, signUp: signup);
    setState(() {
      emailError = nextEmail;
      passwordError = nextPassword;
      message = null;
    });
    if (nextEmail != null || nextPassword != null) return;
    final service = ref.read(pushServiceProvider);
    await _run(() async {
      if (signup) {
        await service.signUp(email.text, password.text);
      } else {
        await service.signIn(email.text, password.text);
      }
      password.clear();
      if (!service.authenticated && signup) {
        setState(() => confirmationEmail = email.text.trim());
      }
      _closeIfSignedIn();
    });
  }

  Future<void> _resend() => _run(() async {
    await ref
        .read(pushServiceProvider)
        .resendEmailConfirmation(emailAddress: confirmationEmail);
    if (mounted) setState(() => message = 'Correo de confirmación reenviado.');
  });

  Future<void> _forgot() async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => PasswordResetSheet(
        service: ref.read(pushServiceProvider),
        initialEmail: email.text.trim(),
      ),
    );
    if (changed == true) _closeIfSignedIn();
  }

  void _switchMode() => setState(() {
    mode = signup ? AuthMode.login : AuthMode.signup;
    message = null;
    emailError = null;
    passwordError = null;
    confirmationEmail = null;
  });

  @override
  Widget build(BuildContext context) {
    final providers =
        ref.watch(oauthProvidersProvider).asData?.value ??
        const <OAuthProvider>{};
    final verb = signup ? 'Crear cuenta' : 'Continuar';
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              signup ? 'Crear cuenta' : 'Iniciar sesión',
              key: const ValueKey('auth-title'),
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 4),
            const Text(
              'Sincroniza favoritos, alertas y Premium.',
              style: TextStyle(color: muted),
            ),
            const SizedBox(height: 18),
            if (confirmationEmail != null)
              _ConfirmationCard(
                email: confirmationEmail!,
                busy: busy,
                onResend: _resend,
              )
            else ...[
              for (final provider in OAuthProvider.values)
                if (providers.contains(provider)) ...[
                  OAuthProviderButton(
                    key: ValueKey('auth-${provider.id}'),
                    provider: provider,
                    label:
                        '${signup ? 'Crear cuenta' : 'Continuar'} con '
                        '${oauthProviderName(provider)}',
                    onPressed: busy ? null : () => _oauth(provider),
                  ),
                  const SizedBox(height: 10),
                ],
              if (providers.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Expanded(child: Divider()),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Text('o', style: TextStyle(color: muted)),
                      ),
                      Expanded(child: Divider()),
                    ],
                  ),
                ),
              TextField(
                key: const ValueKey('auth-email'),
                controller: email,
                enabled: !busy,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: 'Correo',
                  errorText: emailError,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('auth-password'),
                controller: password,
                enabled: !busy,
                obscureText: obscure,
                autofillHints: [
                  signup ? AutofillHints.newPassword : AutofillHints.password,
                ],
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: 'Contraseña',
                  helperText: signup ? 'Mínimo 8 caracteres.' : null,
                  errorText: passwordError,
                  suffixIcon: IconButton(
                    tooltip: obscure
                        ? 'Mostrar contraseña'
                        : 'Ocultar contraseña',
                    onPressed: () => setState(() => obscure = !obscure),
                    icon: Icon(
                      obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 52,
                child: FilledButton(
                  key: const ValueKey('auth-submit'),
                  onPressed: busy ? null : _submit,
                  child: busy
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(verb),
                ),
              ),
              if (!signup)
                TextButton(
                  key: const ValueKey('auth-forgot'),
                  onPressed: busy ? null : _forgot,
                  child: const Text('¿Olvidaste tu contraseña?'),
                ),
            ],
            if (message != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  message!,
                  key: const ValueKey('auth-message'),
                  textAlign: TextAlign.center,
                ),
              ),
            TextButton(
              key: const ValueKey('auth-switch'),
              onPressed: busy ? null : _switchMode,
              child: Text(
                signup
                    ? '¿Ya tienes cuenta? Inicia sesión'
                    : '¿No tienes cuenta? Crea una',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConfirmationCard extends StatelessWidget {
  const _ConfirmationCard({
    required this.email,
    required this.busy,
    required this.onResend,
  });

  final String email;
  final bool busy;
  final VoidCallback onResend;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: panel,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: lime.withValues(alpha: .5)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.mark_email_unread_outlined, color: lime),
            SizedBox(width: 10),
            Text(
              'Confirma tu correo',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Te enviamos un enlace a $email. Ábrelo y vuelve para iniciar sesión.',
          style: const TextStyle(color: muted),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            key: const ValueKey('auth-resend'),
            onPressed: busy ? null : onResend,
            child: const Text('Reenviar correo'),
          ),
        ),
      ],
    ),
  );
}

/// Google / Facebook button, styled per brand guidance.
class OAuthProviderButton extends StatelessWidget {
  const OAuthProviderButton({
    super.key,
    required this.provider,
    required this.label,
    required this.onPressed,
  });

  final OAuthProvider provider;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final google = provider == OAuthProvider.google;
    return SizedBox(
      height: 52,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          backgroundColor: google ? Colors.white : const Color(0xFF1877F2),
          foregroundColor: google ? const Color(0xFF1F1F1F) : Colors.white,
          side: BorderSide.none,
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
        icon: google
            ? const Text(
                'G',
                style: TextStyle(
                  color: Color(0xFF4285F4),
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              )
            : const Icon(Icons.facebook, size: 22),
        label: Text(label),
      ),
    );
  }
}

String oauthProviderName(OAuthProvider provider) =>
    provider == OAuthProvider.google ? 'Google' : 'Facebook';

/// "Google" / "Facebook" / "Correo" for a session's provider id.
String? authProviderLabel(String? id) => switch (id) {
  'google' => 'Google',
  'facebook' => 'Facebook',
  'email' => 'Correo',
  _ => null,
};

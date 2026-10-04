import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

const authFallbackMessage = 'No se pudo completar la operación.';
const authOfflineMessage = 'Sin conexión. Inténtalo de nuevo.';

/// Short Spanish copy for a failed auth/account request (GoTrue REST).
String authErrorMessage(Object error) {
  if (error is SocketException || error is TimeoutException) {
    return authOfflineMessage;
  }
  if (error is! DioException) return authFallbackMessage;

  switch (error.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.connectionError:
      return authOfflineMessage;
    default:
      break;
  }
  final response = error.response;
  if (response == null) {
    return error.error is SocketException || error.error is TimeoutException
        ? authOfflineMessage
        : authFallbackMessage;
  }

  final body = _body(response.data);
  final codes = <String>{
    for (final key in const ['error_code', 'code', 'error'])
      if (body[key] is String) (body[key] as String).trim().toLowerCase(),
  };
  final text = [
    for (final key in const ['msg', 'message', 'error_description'])
      if (body[key] is String) body[key] as String,
  ].join(' ').toLowerCase();

  if (codes.contains('email_not_confirmed') ||
      text.contains('email not confirmed')) {
    return 'Confirma tu correo para iniciar sesión.';
  }
  if (codes.contains('invalid_credentials') ||
      codes.contains('invalid_grant') ||
      text.contains('invalid login credentials')) {
    return 'Correo o contraseña incorrectos.';
  }
  if (codes.contains('user_already_exists') ||
      codes.contains('email_exists') ||
      text.contains('already registered')) {
    return 'Ese correo ya tiene una cuenta. Inicia sesión.';
  }
  if (codes.contains('weak_password') ||
      text.contains('password should be at least')) {
    return 'La contraseña es muy débil (mínimo 8 caracteres).';
  }
  if (response.statusCode == 429 ||
      codes.contains('over_email_send_rate_limit') ||
      codes.contains('over_request_rate_limit')) {
    return 'Demasiados intentos. Espera un momento.';
  }
  if (codes.contains('otp_expired') ||
      text.contains('token has expired or is invalid')) {
    return 'El código no es válido o ya venció.';
  }
  if (codes.contains('same_password')) {
    return 'Usa una contraseña distinta a la anterior.';
  }
  if (codes.contains('signup_disabled') ||
      codes.contains('email_provider_disabled')) {
    return 'El registro no está disponible.';
  }
  return authFallbackMessage;
}

const _rejectedSessionCodes = {
  'refresh_token_not_found',
  'refresh_token_already_used',
  'session_not_found',
  'invalid_grant',
  'bad_jwt',
};

/// True when GoTrue rejected the session itself (invalid or revoked refresh
/// token), as opposed to a transient network/server/proxy failure. A 403
/// counts only with a GoTrue session error code, since proxies and
/// captive portals also answer 403.
bool isAuthRejection(Object error) {
  if (error is! DioException) return false;
  final status = error.response?.statusCode;
  if (status == 400 || status == 401) return true;
  if (status != 403) return false;
  final body = _body(error.response?.data);
  return [
    body['error_code'],
    body['code'],
    body['error'],
  ].any((code) => code is String && _rejectedSessionCodes.contains(code));
}

final _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

String? validateEmail(String value) =>
    _emailPattern.hasMatch(value.trim()) ? null : 'Escribe un correo válido.';

/// New accounts need 8+ characters; sign-in only needs a non-empty password
/// so accounts created under an older, shorter minimum can still log in.
String? validatePassword(String value, {required bool signUp}) {
  if (value.isEmpty) return 'Escribe tu contraseña.';
  if (signUp && value.length < 8) return 'Mínimo 8 caracteres.';
  return null;
}

Map<String, dynamic> _body(dynamic data) {
  if (data is Map) return Map<String, dynamic>.from(data);
  if (data is String && data.trim().startsWith('{')) {
    try {
      final decoded = jsonDecode(data);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
  }
  return const {};
}

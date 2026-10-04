import 'package:dio/dio.dart';

/// Why a read failed, for the copy shown next to "Reintentar". Only a
/// request that never got an answer is "offline"; a server that answered
/// with an error is not the user's connection.
enum LoadFailure { offline, server, other }

LoadFailure classifyLoadError(Object? error) {
  if (error is! DioException) return LoadFailure.other;
  final status = error.response?.statusCode;
  if (status != null) {
    return status >= 500 ? LoadFailure.server : LoadFailure.other;
  }
  return switch (error.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.connectionError => LoadFailure.offline,
    // No answer in time: the server is slow, not the phone offline.
    DioExceptionType.receiveTimeout => LoadFailure.server,
    _ => LoadFailure.other,
  };
}

String loadErrorMessage(Object? error) => switch (classifyLoadError(error)) {
  LoadFailure.offline => 'Sin conexión',
  LoadFailure.server => 'Servicio no disponible por ahora',
  LoadFailure.other => 'No pudimos cargar los datos',
};

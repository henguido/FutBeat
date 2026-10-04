import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/load_errors.dart';

void main() {
  final options = RequestOptions(path: '/v1/calendar');

  DioException status(int code) => DioException(
    requestOptions: options,
    type: DioExceptionType.badResponse,
    response: Response(requestOptions: options, statusCode: code),
  );

  test('only an unanswered request is "Sin conexión"', () {
    for (final type in [
      DioExceptionType.connectionError,
      DioExceptionType.connectionTimeout,
      DioExceptionType.sendTimeout,
    ]) {
      final error = DioException(requestOptions: options, type: type);
      expect(classifyLoadError(error), LoadFailure.offline, reason: '$type');
      expect(loadErrorMessage(error), 'Sin conexión');
    }
  });

  test('a server error or a slow answer is not the connection', () {
    for (final error in [
      status(503),
      status(500),
      DioException(
        requestOptions: options,
        type: DioExceptionType.receiveTimeout,
      ),
    ]) {
      expect(classifyLoadError(error), LoadFailure.server);
      expect(loadErrorMessage(error), 'Servicio no disponible por ahora');
    }
  });

  test('client errors and unknown failures are generic', () {
    expect(classifyLoadError(status(404)), LoadFailure.other);
    expect(classifyLoadError(const FormatException('x')), LoadFailure.other);
    expect(classifyLoadError(null), LoadFailure.other);
    expect(loadErrorMessage(status(401)), 'No pudimos cargar los datos');
  });
}

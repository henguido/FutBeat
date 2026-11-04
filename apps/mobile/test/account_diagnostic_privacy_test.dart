import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/push.dart';

void main() {
  DioException failure(dynamic data, {int? status = 404}) {
    final request = RequestOptions(
      path: 'https://synthetic.test/private-user-id',
      headers: {'Authorization': 'Bearer synthetic-private-access'},
      data: {'refresh_token': 'synthetic-private-refresh'},
    );
    return DioException(
      requestOptions: request,
      type: DioExceptionType.badResponse,
      message: 'private-exception-message',
      response: Response(
        requestOptions: request,
        statusCode: status,
        data: data,
        headers: Headers.fromMap({
          'Set-Cookie': ['synthetic-private-cookie'],
        }),
      ),
    );
  }

  test('account diagnostic omits response messages and all private fields', () {
    expect(
      describeAccountError(
        failure({
          'code': 'PGRST202',
          'message': 'private-review@example.test synthetic-private-token',
          'details': {'user_id': 'private-user-id'},
          'hint': 'private-hint',
        }),
      ),
      'DioException badResponse 404 PGRST202',
    );
  });

  test('known GoTrue error code remains useful without its message', () {
    expect(
      describeAccountError(
        failure({
          'error_code': 'invalid_credentials',
          'message': 'User private-review@example.test failed',
        }, status: 400),
      ),
      'DioException badResponse 400 invalid_credentials',
    );
  });

  test('untrusted error-code values cannot become a logging side channel', () {
    for (final code in <Object>[
      'private-review@example.test',
      'Bearer synthetic-private-access',
      'synthetic_private_token',
      'PGRST202\nprivate-user-id',
      {'token': 'synthetic-private-access'},
      ['private-user-id'],
      12345,
    ]) {
      expect(
        describeAccountError(failure({'code': code})),
        'DioException badResponse 404',
      );
    }
  });

  test('non-map body and absent response retain only bounded metadata', () {
    expect(
      describeAccountError(failure('<html>private-user-id</html>')),
      'DioException badResponse 404',
    );
    expect(
      describeAccountError(
        DioException(
          requestOptions: RequestOptions(path: '/private-user-id'),
          type: DioExceptionType.connectionError,
          error: StateError('synthetic-private-refresh'),
          message: 'private-exception-message',
        ),
      ),
      'DioException connectionError -',
    );
  });

  test('non-Dio exceptions disclose type only, never their message', () {
    expect(describeAccountError(StateError('private-user-id')), 'StateError');
  });
}

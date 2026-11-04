import 'package:dio/dio.dart';

/// Bounded, fail-closed transport for the dedicated API276 Preview function.
/// Construct on a dedicated Dio before it can send any request.
class PassivePreviewTransport extends Interceptor {
  PassivePreviewTransport({
    required this.baseUri,
    String? clientKey,
    DateTime Function()? clock,
    this.sessionLimit = 30,
    this.minuteLimit = 8,
    this.concurrentLimit = 2,
  }) : _clock = clock ?? DateTime.now,
       _clientKey = clientKey {
    if (baseUri.scheme != 'https' ||
        baseUri.host.isEmpty ||
        baseUri.authority.contains('@') ||
        baseUri.hasQuery ||
        baseUri.hasFragment ||
        baseUri.path != '/functions/v1/futbeat-passive-api' ||
        (clientKey != null &&
            RegExp(r'^[!-~]{16,200}$').stringMatch(clientKey) != clientKey) ||
        sessionLimit < 1 ||
        sessionLimit > 30 ||
        minuteLimit < 1 ||
        minuteLimit > 8 ||
        concurrentLimit < 1 ||
        concurrentLimit > 2) {
      throw ArgumentError('Invalid passive Preview transport policy');
    }
  }

  final Uri baseUri;
  final DateTime Function() _clock;
  final String? _clientKey;
  final int sessionLimit, minuteLimit, concurrentLimit;
  bool _closed = false;
  int _used = 0, _blocked = 0;
  final _recent = <DateTime>[];
  final _active = <RequestOptions>{};
  static const _budgetWindow = Duration(minutes: 15);
  static const _queryKeys = {
    'id',
    'type',
    'date',
    'timezone',
    'scope',
    'cursor',
    'limit',
    'competitionId',
    'season',
    'bucket',
    'until',
    'keys',
    'country',
    'q',
  };

  static const _routes = {
    '/v1/calendar',
    '/v1/match-context',
    '/v1/match-detail',
    '/v1/match-preview',
    '/v1/match-h2h',
    '/v1/entity',
    '/v1/team-context',
    '/v1/team-matches',
    '/v1/standings-form',
    '/v1/favorites',
    '/v1/explore',
    '/v1/search',
  };

  Map<String, int> get counters => {
    'requests': _used,
    'active': _active.length,
    'blocked': _blocked,
  };

  void close() {
    _closed = true;
    final pending = _active.toList();
    _active.clear();
    for (final request in pending) {
      request.headers.remove('x-futbeat-client-key');
      request.cancelToken?.cancel('Passive Preview session closed');
    }
  }

  DioException _blockedRequest(RequestOptions options) => DioException(
    requestOptions: options,
    type: DioExceptionType.cancel,
    error: 'Passive Preview request unavailable',
  );

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final now = _clock();
    _recent.removeWhere((time) => now.difference(time) >= _budgetWindow);
    final minuteRequests = _recent
        .where((time) => now.difference(time) < const Duration(minutes: 1))
        .length;
    final path = options.path;
    final params = Map<String, dynamic>.of(options.queryParameters);
    // Ordinary detail reads pass request=0 to opt out of hydration. The
    // passive route never hydrates and receives no demand argument.
    final hasDemandFlag = params.containsKey('request');
    final request = params.remove('request');
    // Accept only the repository's relative contract paths. Dio resolves the
    // rewritten path under the dedicated function base, never a caller URL.
    if (_closed ||
        options.method != 'GET' ||
        options.data != null ||
        !_routes.contains(path) ||
        options.baseUrl != baseUri.toString() ||
        (hasDemandFlag && (path != '/v1/match-detail' || request != '0')) ||
        params.keys.any((key) => !_queryKeys.contains(key)) ||
        options.cancelToken?.isCancelled == true ||
        _recent.length >= sessionLimit ||
        minuteRequests >= minuteLimit ||
        _active.length >= concurrentLimit) {
      _blocked++;
      handler.reject(_blockedRequest(options));
      return;
    }

    options.path = path.replaceFirst('/v1/', '/v1/qa-stored/');
    options.queryParameters = params;
    options.headers
      ..clear()
      ..['accept'] = 'application/json';
    if (_clientKey != null) {
      options.headers['x-futbeat-client-key'] = _clientKey;
    }
    options.followRedirects = false;
    options.validateStatus = (status) => status == 200;
    options.cancelToken ??= CancelToken();
    options.connectTimeout = const Duration(seconds: 8);
    options.receiveTimeout = const Duration(seconds: 8);
    _used++;
    _recent.add(now);
    _active.add(options);
    handler.next(options);
  }

  void _settle(RequestOptions options) {
    if (_active.remove(options)) options.headers.remove('x-futbeat-client-key');
  }

  bool _accepted(Response<dynamic> response) {
    final stored = response.headers['x-futbeat-qa-stored'];
    final passive = response.headers['x-futbeat-passive'];
    final status = response.statusCode ?? 0;
    return !_closed &&
        (status == 200 || status >= 400) &&
        status != 401 &&
        status != 403 &&
        stored?.length == 1 &&
        stored!.single == 'v1' &&
        passive?.length == 1 &&
        passive!.single == 'v1';
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    _settle(response.requestOptions);
    if (_accepted(response)) {
      handler.next(response);
    } else {
      close();
      handler.reject(_blockedRequest(response.requestOptions));
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _settle(err.requestOptions);
    final response = err.response;
    if (response != null && !_accepted(response)) {
      close();
      handler.reject(_blockedRequest(err.requestOptions));
      return;
    }
    handler.next(err);
  }
}

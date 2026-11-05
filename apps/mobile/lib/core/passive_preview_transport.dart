import 'dart:async';

import 'package:dio/dio.dart';

/// Bounded, fail-closed transport for the dedicated API277 Preview function.
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
  DateTime? _retryAfter;
  final _cache = <String, ({DateTime expires, Response<dynamic> response})>{};
  static const _cacheLimit = 30;
  int _used = 0, _blocked = 0;
  final _recent = <DateTime>[];
  final _active = <RequestOptions>{};
  final _waiting = <RequestOptions>{};
  var _slotChanged = Completer<void>();
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
    _cache.clear();
    final pending = [..._active, ..._waiting];
    _active.clear();
    for (final request in pending) {
      request.headers.remove('x-futbeat-client-key');
      request.cancelToken?.cancel('Passive Preview session closed');
    }
    _releaseWaiters();
  }

  DioException _blockedRequest(RequestOptions options) => DioException(
    requestOptions: options,
    type: DioExceptionType.cancel,
    error: 'Passive Preview request unavailable',
  );

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    options.cancelToken ??= CancelToken();
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
        options.cancelToken?.isCancelled == true) {
      _blocked++;
      handler.reject(_blockedRequest(options));
      return;
    }

    options.path = path.replaceFirst('/v1/', '/v1/qa-stored/');
    options.queryParameters = params;
    if (_serveCached(options, handler)) return;
    if (!await _waitForSlot(options)) {
      _blocked++;
      handler.reject(_blockedRequest(options));
      return;
    }
    final now = _clock();
    _recent.removeWhere((time) => now.difference(time) >= _budgetWindow);
    final minuteRequests = _recent
        .where((time) => now.difference(time) < const Duration(minutes: 1))
        .length;
    if (_serveCached(options, handler)) return;
    if (_closed ||
        options.cancelToken!.isCancelled ||
        _retryAfter?.isAfter(now) == true ||
        _recent.length >= sessionLimit ||
        minuteRequests >= minuteLimit) {
      _settle(options);
      _blocked++;
      handler.reject(_blockedRequest(options));
      return;
    }
    options.headers
      ..clear()
      ..['accept'] = 'application/json';
    if (_clientKey != null) {
      options.headers['x-futbeat-client-key'] = _clientKey;
    }
    options.followRedirects = false;
    options.validateStatus = (status) => status == 200;
    options.connectTimeout = const Duration(seconds: 8);
    options.receiveTimeout = const Duration(seconds: 8);
    _used++;
    _recent.add(now);
    handler.next(options);
  }

  bool _serveCached(RequestOptions options, RequestInterceptorHandler handler) {
    if (_closed || options.cancelToken!.isCancelled) return false;
    final now = _clock();
    _cache.removeWhere((_, entry) => !now.isBefore(entry.expires));
    final cached = _cache[_cacheKey(options)];
    if (cached != null) {
      _settle(options);
      final response = Response<dynamic>(
        requestOptions: options,
        statusCode: cached.response.statusCode,
        data: cached.response.data,
        headers: cached.response.headers,
      );
      if (response.statusCode == 404) {
        handler.reject(
          DioException.badResponse(
            statusCode: 404,
            requestOptions: options,
            response: response,
          ),
        );
      } else {
        handler.resolve(response);
      }
      return true;
    }
    return false;
  }

  Future<bool> _waitForSlot(RequestOptions options) async {
    if (_waiting.length >= sessionLimit) return false;
    final elapsed = Stopwatch()..start();
    _waiting.add(options);
    try {
      while (_active.length >= concurrentLimit) {
        if (_closed || options.cancelToken!.isCancelled) return false;
        final remaining = const Duration(seconds: 8) - elapsed.elapsed;
        if (remaining <= Duration.zero) return false;
        await Future.any<void>([
          _slotChanged.future,
          options.cancelToken!.whenCancel.then((_) {}),
        ]).timeout(remaining);
      }
      if (_closed || options.cancelToken!.isCancelled) return false;
      _active.add(options);
      return true;
    } on TimeoutException {
      return false;
    } finally {
      _waiting.remove(options);
    }
  }

  void _releaseWaiters() {
    final signal = _slotChanged;
    _slotChanged = Completer<void>();
    signal.complete();
  }

  String _cacheKey(RequestOptions options) {
    final query = options.uri.queryParametersAll;
    final keys = query.keys.toList()..sort();
    return Uri(
      path: options.uri.path,
      queryParameters: {for (final key in keys) key: query[key]},
    ).toString();
  }

  void _remember(Response<dynamic> response) {
    final now = _clock();
    final status = response.statusCode;
    if (status == 429 || status == 503) {
      final values = response.headers['retry-after'];
      final seconds = values?.length == 1 ? int.tryParse(values!.single) : null;
      final deadline = now.add(
        Duration(
          seconds: seconds != null && seconds > 0
              ? seconds
              : (status == 429 ? 60 : 2),
        ),
      );
      if (_retryAfter?.isAfter(deadline) != true) _retryAfter = deadline;
      return;
    }
    if (status != 200 && status != 404) return;
    final directives = (response.headers['cache-control'] ?? const <String>[])
        .join(',')
        .toLowerCase()
        .split(',')
        .map((value) => value.trim());
    final age = RegExp(r'^max-age=(\d+)$');
    final maxAge = directives.map(age.firstMatch).nonNulls.firstOrNull;
    final seconds = status == 404
        ? 30
        : int.tryParse(maxAge?.group(1) ?? '') ?? 0;
    if (seconds <= 0 ||
        (status == 200 &&
            (directives.contains('no-store') ||
                directives.contains('no-cache')))) {
      return;
    }
    final key = _cacheKey(response.requestOptions);
    _cache.remove(key);
    if (_cache.length >= _cacheLimit) _cache.remove(_cache.keys.first);
    _cache[key] = (
      expires: now.add(Duration(seconds: seconds)),
      response: response,
    );
  }

  void _settle(RequestOptions options) {
    if (_active.remove(options)) {
      options.headers.remove('x-futbeat-client-key');
      _releaseWaiters();
    }
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
      _remember(response);
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
    if (response != null) _remember(response);
    handler.next(err);
  }
}

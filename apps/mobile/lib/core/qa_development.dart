import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Staged QA227 policy. Ordinary builds keep all existing behavior.
const qaLocalCacheOnly = bool.fromEnvironment('FUTBEAT_QA_LOCAL_CACHE_ONLY');

class QaOfflineHttpOverrides extends HttpOverrides {
  static int blockedClients = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    blockedClients++;
    if (qaLocalCacheOnly) {
      debugPrint('FB_QA_OFFLINE blocked_http_client=$blockedClients');
    }
    throw const SocketException('QA local cache mode: network disabled');
  }
}

void installQaLocalCachePolicy() {
  if (!qaLocalCacheOnly) return;
  if (!kDebugMode ||
      const bool.fromEnvironment('FUTBEAT_USE_DEMO') ||
      !const bool.fromEnvironment('FUTBEAT_ADS_DISABLED') ||
      const bool.fromEnvironment('FUTBEAT_PUSH_ENABLED') ||
      const bool.fromEnvironment('FUTBEAT_OAUTH_GOOGLE_ENABLED') ||
      const bool.fromEnvironment('FUTBEAT_OAUTH_FACEBOOK_ENABLED')) {
    throw StateError(
      'QA local cache mode requires debug, no demo, Ads/OAuth/Push off',
    );
  }
  HttpOverrides.global = QaOfflineHttpOverrides();
}

/// A passive detail reader's acknowledged 404 means no stored answer, not
/// pending provider work. Never infer that meaning from an ordinary endpoint,
/// disabled reader (no ACK), forbidden response, write or another stored route.
bool isQaStoredDetailAbsent(Object error) {
  if (error is! DioException ||
      error.response?.statusCode != 404 ||
      error.requestOptions.method != 'GET' ||
      error.requestOptions.path != '/v1/qa-stored/match-detail') {
    return false;
  }
  final acknowledgment = error.response!.headers['x-futbeat-qa-stored'];
  return acknowledgment?.length == 1 && acknowledgment!.single == 'v1';
}

/// Opt-in adapter for the proposed stored-only API. It cannot call ordinary
/// demand-aware routes, including on an older server that lacks this contract.
/// Not installed in repositoryProvider until backend + controller activation
/// is explicitly approved. Tests exercise it against local fixture servers.
class QaStoredReadInterceptor extends Interceptor {
  QaStoredReadInterceptor({
    required this.origin,
    DateTime Function()? clock,
    this.sessionLimit = 60,
    this.minuteLimit = 12,
    this.concurrentLimit = 2,
    this.sessionDuration = const Duration(hours: 3),
  }) : clock = clock ?? DateTime.now {
    if (origin.scheme != 'https' ||
        origin.host.isEmpty ||
        origin.userInfo.isNotEmpty ||
        sessionLimit < 1 ||
        sessionLimit > 60 ||
        minuteLimit < 1 ||
        minuteLimit > 12 ||
        concurrentLimit < 1 ||
        concurrentLimit > 2 ||
        sessionDuration <= Duration.zero ||
        sessionDuration > const Duration(hours: 3)) {
      throw ArgumentError('Invalid QA stored-read policy');
    }
    _expiresAt = this.clock().add(sessionDuration);
  }

  final Uri origin;
  final DateTime Function() clock;
  final Duration sessionDuration;
  late final DateTime _expiresAt;
  Timer? _expiryTimer;
  final int sessionLimit, minuteLimit, concurrentLimit;
  int _used = 0, _active = 0, _blocked = 0;
  bool _closed = false;
  final List<DateTime> _recent = [];
  final Set<RequestOptions> _owned = {};
  static const _routes = {
    '/v1/calendar',
    '/v1/match-context',
    '/v1/match-detail',
  };
  Map<String, int> get counters => {
    'requests': _used,
    'active': _active,
    'blocked': _blocked,
  };
  void close() {
    _closed = true;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    final pending = _owned.toList();
    _owned.clear();
    _active = 0;
    for (final options in pending) {
      options.cancelToken?.cancel('QA development STOP');
    }
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final uri = options.uri;
    final now = clock();
    if (!now.isBefore(_expiresAt)) close();
    _recent.removeWhere(
      (at) => now.difference(at) >= const Duration(minutes: 1),
    );
    final allowed =
        !_closed &&
        now.isBefore(_expiresAt) &&
        options.method == 'GET' &&
        _routes.contains(options.path) &&
        uri.scheme == origin.scheme &&
        uri.host == origin.host &&
        uri.port == origin.port &&
        uri.userInfo.isEmpty &&
        options.baseUrl == origin.toString() &&
        _used < sessionLimit &&
        _recent.length < minuteLimit &&
        _active < concurrentLimit;
    if (!allowed) {
      _blocked++;
      handler.reject(
        DioException(
          requestOptions: options,
          error: 'QA read policy blocked request',
          type: DioExceptionType.cancel,
        ),
      );
      return;
    }
    options.path = options.path.replaceFirst('/v1/', '/v1/qa-stored/');
    options.followRedirects = false;
    options.cancelToken ??= CancelToken();
    options.receiveTimeout = const Duration(seconds: 8);
    _used++;
    _active++;
    _recent.add(now);
    _owned.add(options);
    _expiryTimer ??= Timer(_expiresAt.difference(now), close);
    handler.next(options);
  }

  void _settle(RequestOptions options) {
    if (_owned.remove(options)) _active--;
    if (_active == 0) {
      _expiryTimer?.cancel();
      _expiryTimer = null;
    }
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    _settle(response.requestOptions);
    if (!clock().isBefore(_expiresAt) ||
        response.headers.value('x-futbeat-qa-stored') != 'v1') {
      close();
      handler.reject(
        DioException(
          requestOptions: response.requestOptions,
          error: 'QA stored-read contract unavailable',
          type: DioExceptionType.cancel,
        ),
      );
    } else {
      handler.next(response);
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _settle(err.requestOptions);
    if (err.response != null &&
        err.response!.headers.value('x-futbeat-qa-stored') != 'v1') {
      close();
    }
    handler.next(err);
  }
}

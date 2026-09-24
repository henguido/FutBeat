import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database.dart';
import 'live_realtime.dart';
import 'models.dart';

abstract interface class FootballRepository {
  Future<Snapshot> load();
  Future<Snapshot> loadDate(DateTime date);
  Future<MatchDetail> loadMatchDetail(String id);
}

class DemoRepository implements FootballRepository {
  @override
  Future<Snapshot> load() async => Snapshot(
    jsonDecode(await rootBundle.loadString('assets/demo.snapshot.json'))
        as Json,
  );

  @override
  Future<Snapshot> loadDate(DateTime date) => load();

  @override
  Future<MatchDetail> loadMatchDetail(String id) async => MatchDetail.empty(id);
}

class ApiRepository implements FootballRepository {
  ApiRepository(this.dio, [this.database]);
  final Dio dio;
  final AppDatabase? database;

  final Map<String, DateTime> _calendarFetchedAt = {};
  final Map<String, Future<Snapshot>> _calendarInFlight = {};
  final Set<String> _forcedDates = {};
  final Map<String, DateTime> _catalogFetchedAt = {};
  final Set<String> _detailRequested = {};
  final Map<String, Future<MatchDetail>> _detailRequestInFlight = {};

  final Map<String, Snapshot> _snapshotCache = <String, Snapshot>{};

  static String _dateParam(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  Snapshot _canonical(Json json) {
    final snapshot = Snapshot(json);
    if (snapshot.demo) {
      throw StateError('Cloud endpoint returned demo data');
    }
    return snapshot;
  }

  bool _retryable(Object error) {
    if (error is! DioException) return false;
    final status = error.response?.statusCode;
    if (status == 502 || status == 503 || status == 504) return true;
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError ||
      DioExceptionType.unknown => true,
      _ => false,
    };
  }

  Future<Json> _getJson(
    String path, {
    Map<String, dynamic>? queryParameters,
    int maxAttempts = 2,
    CancelToken? cancelToken,
  }) async {
    Object? lastError;
    StackTrace? lastStack;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final response = await dio.get<Json>(
          path,
          queryParameters: queryParameters,
          cancelToken: cancelToken,
          options: Options(
            receiveTimeout: path == '/v1/match-detail'
                ? const Duration(seconds: 3)
                : null,
            headers: {if (attempt > 0) 'X-Retry-Count': '1'},
          ),
        );
        final data = response.data;
        if (data == null) {
          throw const FormatException('Cloud endpoint returned no data');
        }
        return data;
      } catch (error, stack) {
        lastError = error;
        lastStack = stack;
        if (attempt + 1 < maxAttempts && _retryable(error)) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          continue;
        }
        break;
      }
    }

    Error.throwWithStackTrace(lastError!, lastStack!);
  }

  void _remember(String key, Snapshot snapshot) {
    _snapshotCache.remove(key);
    _snapshotCache[key] = snapshot;
    while (_snapshotCache.length > 64) {
      final oldest = _snapshotCache.keys.first;
      _snapshotCache.remove(oldest);
      if (oldest.startsWith('calendar:')) {
        _calendarFetchedAt.remove(oldest.substring('calendar:'.length));
      }
    }
  }

  Future<Snapshot> _loadSnapshot(
    String key,
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    try {
      final snapshot = _canonical(
        await _getJson(path, queryParameters: queryParameters),
      );
      _remember(key, snapshot);
      return snapshot;
    } catch (error, stack) {
      final cached = _snapshotCache[key];
      if (cached != null) return cached.asStale();
      Error.throwWithStackTrace(error, stack);
    }
  }

  @override
  Future<Snapshot> load() => _loadSnapshot('snapshot', '/v1/snapshot');

  bool _freshDate(String value) {
    if (_forcedDates.contains(value)) return false;
    final fetched = _calendarFetchedAt[value];
    if (fetched == null) return false;
    final today = _dateParam(costaRicaNow());
    final snapshot = _snapshotCache['calendar:$value'];
    final recovering =
        snapshot?.coverage?['partial'] == true || snapshot?.stale == true;
    final ttl = recovering
        ? const Duration(seconds: 20)
        : value.compareTo(today) < 0
        ? const Duration(seconds: 30)
        : value == today
        ? const Duration(seconds: 20)
        : const Duration(seconds: 30);
    return DateTime.now().toUtc().difference(fetched) < ttl;
  }

  Future<Snapshot> _fetchDate(String value, {CancelToken? cancelToken}) {
    return _calendarInFlight.putIfAbsent(value, () async {
      try {
        final raw = await _getJson(
          '/v1/calendar',
          queryParameters: {'date': value, 'timezone': 'America/Costa_Rica'},
          cancelToken: cancelToken,
          maxAttempts: 1,
        );
        final fresh = _canonical(raw);
        _remember('calendar:$value', fresh);
        _calendarFetchedAt[value] = DateTime.now().toUtc();
        await database?.saveCalendarSnapshot(value, jsonEncode(raw));
        _forcedDates.remove(value);
        return fresh;
      } finally {
        _calendarInFlight.remove(value);
      }
    });
  }

  @override
  Future<Snapshot> loadDate(DateTime date) => _fetchDate(_dateParam(date));

  Stream<Snapshot> watchDate(
    DateTime date, {
    CancelToken? cancelToken,
    Duration retryDelay = const Duration(seconds: 3),
  }) async* {
    final value = _dateParam(date);
    final key = 'calendar:$value';
    Snapshot? cached = _snapshotCache[key];
    if (cached == null) {
      final stored = await database?.readCalendarEntry(value);
      if (stored != null) {
        try {
          cached = _canonical(jsonDecode(stored.payload) as Json);
          _remember(key, cached);
          _calendarFetchedAt[value] = stored.savedAt.toUtc();
        } catch (_) {
          // A corrupt local row is replaced by the next successful response.
        }
      }
    }
    final freshCache = cached != null && _freshDate(value);
    if (cached != null) yield cached.withFreshness(revalidating: !freshCache);
    if (freshCache) return;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (cancelToken?.isCancelled == true) return;
      try {
        cached = await _fetchDate(value, cancelToken: cancelToken);
        yield cached;
        // Only today's visible load may prefetch. Prefetch itself never recurses.
        if (value == _dateParam(costaRicaNow())) {
          unawaited(prefetchDate(date.subtract(const Duration(days: 1))));
          unawaited(prefetchDate(date.add(const Duration(days: 1))));
        }
        return;
      } catch (error, stack) {
        if (cancelToken?.isCancelled == true) return;
        if (cached != null) yield cached.asStale();
        if (attempt == 2) {
          if (cached == null) Error.throwWithStackTrace(error, stack);
          return;
        }
        await Future.any([
          Future<void>.delayed(retryDelay * (attempt + 1)),
          if (cancelToken != null) cancelToken.whenCancel,
        ]);
      }
    }
  }

  Future<void> prefetchDate(DateTime date) async {
    final value = _dateParam(date);
    if (_snapshotCache.containsKey('calendar:$value') ||
        await database?.readCalendarSnapshot(value) != null) {
      return;
    }
    try {
      await _fetchDate(value);
    } catch (_) {
      // Opportunistic, deduplicated and independent of the visible request.
    }
  }

  void refreshDate(DateTime date) {
    _forcedDates.add(_dateParam(date));
    _calendarFetchedAt.remove(_dateParam(date));
  }

  Future<Snapshot> loadEntity(String type, String id) => _loadSnapshot(
    'entity:$type:$id',
    '/v1/entity',
    queryParameters: {'type': type, 'id': id},
  );

  Future<Snapshot> loadMatchContext(String id) => _loadSnapshot(
    'match-context:$id',
    '/v1/match-context',
    queryParameters: {'id': id},
  );

  Future<Snapshot> loadExplore({CancelToken? cancelToken}) =>
      _loadCatalog('explore', '/v1/explore', cancelToken: cancelToken);

  Future<Snapshot> _loadCatalog(
    String key,
    String path, {
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
  }) async {
    final cached = _snapshotCache[key];
    final fetched = _catalogFetchedAt[key];
    // A partial answer (remote discovery pending) is never served from cache.
    if (cached != null &&
        !cached.pendingRemote &&
        fetched != null &&
        DateTime.now().difference(fetched) < const Duration(minutes: 1)) {
      return cached;
    }
    final snapshot = _canonical(
      await _getJson(
        path,
        queryParameters: queryParameters,
        cancelToken: cancelToken,
        maxAttempts: 1,
      ),
    );
    _remember(key, snapshot);
    _catalogFetchedAt.removeWhere(
      (key, value) => !_snapshotCache.containsKey(key),
    );
    _catalogFetchedAt[key] = DateTime.now();
    return snapshot;
  }

  Future<Snapshot> searchCatalog(
    String query,
    String? country, {
    CancelToken? cancelToken,
  }) {
    final normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.length < 2) {
      return loadExplore(cancelToken: cancelToken);
    }
    return _loadCatalog(
      'search:$normalizedQuery',
      '/v1/search',
      queryParameters: {'q': normalizedQuery},
      cancelToken: cancelToken,
    );
  }

  Future<Snapshot> loadFavorites(List<String> keys) {
    final normalizedKeys = [...keys]..sort();
    return _loadSnapshot(
      'favorites:${normalizedKeys.join(',')}',
      '/v1/favorites',
      queryParameters: {'keys': normalizedKeys.join(',')},
    );
  }

  @override
  Future<MatchDetail> loadMatchDetail(
    String id, {
    CancelToken? cancelToken,
  }) async {
    final cached = await readMatchDetail(id, cancelToken: cancelToken);
    if (cached.available || _detailRequested.contains(id)) return cached;
    return _detailRequestInFlight.putIfAbsent(id, () async {
      try {
        final detail = MatchDetail(
          await _getJson(
            '/v1/match-detail',
            queryParameters: {'id': id},
            maxAttempts: 1,
            cancelToken: cancelToken,
          ),
        );
        // Remember accepted requests only. Errors/timeouts remain retryable.
        _detailRequested.add(id);
        return detail;
      } finally {
        _detailRequestInFlight.remove(id);
      }
    });
  }

  Future<MatchDetail> readMatchDetail(
    String id, {
    CancelToken? cancelToken,
  }) async => MatchDetail(
    await _getJson(
      '/v1/match-detail',
      queryParameters: {'id': id, 'request': '0'},
      maxAttempts: 1,
      cancelToken: cancelToken,
    ),
  );
}

final repositoryProvider = Provider<FootballRepository>((ref) {
  const useDemo = bool.fromEnvironment('FUTBEAT_USE_DEMO');
  const baseUrl = String.fromEnvironment(
    'FUTBEAT_API_URL',
    defaultValue:
        'https://izlmruqawgagwdcsjhte.supabase.co/functions/v1/futbeat-api',
  );
  const publicToken = String.fromEnvironment('FUTBEAT_API_PUBLIC_TOKEN');
  if (useDemo) return DemoRepository();
  final dio = Dio(
    BaseOptions(
      baseUrl: baseUrl,
      headers: publicToken.isEmpty
          ? null
          : {'Authorization': 'Bearer $publicToken'},
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 15),
    ),
  );

  ref.onDispose(() => dio.close(force: true));
  return ApiRepository(dio, ref.watch(databaseProvider));
});

final snapshotProvider = FutureProvider<Snapshot>(
  (ref) => ref.watch(repositoryProvider).load(),
);

final calendarSnapshotProvider = StreamProvider.autoDispose
    .family<Snapshot, DateTime>((ref, date) async* {
      final repository = ref.watch(repositoryProvider);
      if (repository is! ApiRepository) {
        yield await repository.loadDate(date);
        return;
      }
      final token = CancelToken();
      Timer? timer;
      var disposed = false;
      ref.onDispose(() {
        disposed = true;
        token.cancel('Calendar date closed');
        timer?.cancel();
      });
      try {
        yield* repository.watchDate(date, cancelToken: token);
      } finally {
        // Revalidate while visible, including after exhausted network retries.
        // Never overlap a slow request or keep polling after the screen closes.
        if (!disposed) {
          timer = Timer(const Duration(seconds: 30), ref.invalidateSelf);
        }
      }
    });

final entitySnapshotProvider =
    FutureProvider.family<Snapshot, ({String type, String id})>((
      ref,
      request,
    ) async {
      final repository = ref.watch(repositoryProvider);
      if (repository is ApiRepository) {
        return repository.loadEntity(request.type, request.id);
      }
      return repository.load();
    });

final exploreSnapshotProvider = FutureProvider.autoDispose<Snapshot>((
  ref,
) async {
  final repository = ref.watch(repositoryProvider);
  final token = CancelToken();
  ref.onDispose(() => token.cancel('Explore closed'));
  final value = await (repository is ApiRepository
      ? repository.loadExplore(cancelToken: token)
      : repository.load());
  if (ref.mounted) {
    final link = ref.keepAlive();
    final expiry = Timer(const Duration(minutes: 1), link.close);
    ref.onDispose(expiry.cancel);
  }
  return value;
});

final searchSnapshotProvider = FutureProvider.autoDispose
    .family<Snapshot, ({String query, String? country})>((ref, request) async {
      final repository = ref.watch(repositoryProvider);
      final token = CancelToken();
      ref.onDispose(() => token.cancel('Search superseded'));
      if (repository is ApiRepository) {
        return repository.searchCatalog(
          request.query,
          null,
          cancelToken: token,
        );
      }
      return repository.load();
    });

final favoritesSnapshotProvider = FutureProvider.family<Snapshot, String>((
  ref,
  encodedKeys,
) async {
  final repository = ref.watch(repositoryProvider);
  if (repository is ApiRepository) {
    final keys = encodedKeys
        .split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    return repository.loadFavorites(keys);
  }
  return repository.load();
});

/// Settled match data stays cached for this long after it loads, so leaving
/// and re-entering a match shortly after does not refetch it.
const matchCacheRetention = Duration(minutes: 1);

void _retainSettled(Ref ref) {
  final link = ref.keepAlive();
  final expiry = Timer(matchCacheRetention, link.close);
  ref.onDispose(expiry.cancel);
}

final matchContextSnapshotProvider = FutureProvider.autoDispose
    .family<Snapshot, String>((ref, id) async {
      final repository = ref.watch(repositoryProvider);
      final value = await (repository is ApiRepository
          ? repository.loadMatchContext(id)
          : repository.load());
      // Data still arriving is re-read, never pinned by the retention cache.
      if (ref.mounted && !value.standingsPending) _retainSettled(ref);
      return value;
    });

final detailPollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 5),
);

/// Bounded, growing read-only refreshes while the server reports pending
/// sections (5 s, 10 s, 20 s, 40 s by default), then stop.
final detailPollScheduleProvider = Provider<List<Duration>>((ref) {
  final base = ref.watch(detailPollIntervalProvider);
  return [base, base * 2, base * 4, base * 8];
});

/// Upper bound for any single detail read.
final detailReadTimeoutProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 5),
);

/// Last good detail per match for this app session. A refresh (retry,
/// re-entry) starts from it instead of an empty "loading" state, so arriving
/// data never flickers away and a failed refresh never erases a lineup.
final matchDetailMemoryProvider = Provider<Map<String, MatchDetail>>(
  (ref) => <String, MatchDetail>{},
);

final matchDetailProvider = StreamProvider.autoDispose
    .family<MatchDetail, String>((ref, id) async* {
      final repository = ref.watch(repositoryProvider);
      final memory = ref.watch(matchDetailMemoryProvider);
      final readTimeout = ref.read(detailReadTimeoutProvider);
      var disposed = false;
      Timer? timer;
      Completer<void>? waiting;
      var requestToken = CancelToken();
      ref.onDispose(() {
        disposed = true;
        timer?.cancel();
        requestToken.cancel('Match Center closed');
        if (waiting != null && !waiting.isCompleted) waiting.complete();
      });
      void remember(MatchDetail detail) {
        if (detail.available) memory[id] = detail;
      }

      // Cache-first: the last good detail (if any) is shown immediately.
      var current = memory[id] ?? MatchDetail.waiting(id);
      yield current;
      if (disposed) return;
      try {
        current =
            await (repository is ApiRepository
                    ? repository.loadMatchDetail(id, cancelToken: requestToken)
                    : repository.loadMatchDetail(id))
                .timeout(
                  readTimeout,
                  onTimeout: () {
                    requestToken.cancel('Initial detail deadline');
                    throw TimeoutException('Initial detail deadline');
                  },
                );
        remember(current);
      } catch (_) {
        // A failed read is not evidence that data is absent: keep what we
        // had and try bounded read-only refreshes.
        current = memory[id] ?? MatchDetail.waiting(id);
      }
      if (disposed) return;
      yield current;

      if (repository is! ApiRepository) {
        if (current.pending) {
          yield MatchDetail({...current.json, 'pending': false});
        }
        return;
      }

      for (final delay in ref.read(detailPollScheduleProvider)) {
        if (!current.pending) break;
        waiting = Completer<void>();
        timer = Timer(delay, () => waiting!.complete());
        await waiting.future;
        if (disposed) return;
        try {
          requestToken = CancelToken();
          final next = await repository
              .readMatchDetail(id, cancelToken: requestToken)
              .timeout(
                readTimeout,
                onTimeout: () {
                  requestToken.cancel('Detail read deadline');
                  throw TimeoutException('Detail read deadline');
                },
              );
          if (disposed) return;
          // Never replace real data with an emptier answer.
          if (next.available || !current.available) current = next;
          remember(current);
          yield current;
        } catch (_) {
          // Retain the latest detail; the schedule stays bounded.
        }
      }
      final complete = !current.pending;
      if (!disposed && current.pending) {
        current = MatchDetail({...current.json, 'pending': false});
        yield current;
      }
      // Retain only real, complete detail; an incomplete one is re-read on
      // the next visit.
      if (!disposed && current.available && complete) _retainSettled(ref);
    });

final liveRealtimeConfigProvider = Provider<LiveRealtimeConfig>(
  (ref) => LiveRealtimeConfig.fromEnvironment(),
);

final liveRealtimeClientProvider = Provider<LiveRealtimeClient>((ref) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
    ),
  );
  ref.onDispose(() => dio.close(force: true));
  return LiveRealtimeClient(ref.watch(liveRealtimeConfigProvider), dio);
});

final liveMatchUpdatesProvider = StreamProvider<Map<String, LiveMatchUpdate>>(
  (ref) => ref.watch(liveRealtimeClientProvider).watch(),
);

final effectiveSnapshotProvider = Provider<AsyncValue<Snapshot>>((ref) {
  final updates =
      ref.watch(liveMatchUpdatesProvider).asData?.value ??
      const <String, LiveMatchUpdate>{};
  return ref
      .watch(snapshotProvider)
      .whenData((snapshot) => snapshot.withLiveUpdates(updates));
});

final effectiveCalendarSnapshotProvider = Provider.autoDispose
    .family<AsyncValue<Snapshot>, DateTime>((ref, date) {
      final updates =
          ref.watch(liveMatchUpdatesProvider).asData?.value ??
          const <String, LiveMatchUpdate>{};
      return ref
          .watch(calendarSnapshotProvider(date))
          .whenData((snapshot) => snapshot.withLiveUpdates(updates));
    });

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});
final followsProvider = StreamProvider<Set<String>>(
  (ref) => ref.watch(databaseProvider).watchFollows(),
);

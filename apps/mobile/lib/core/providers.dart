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
            headers: attempt == 0 ? null : const {'X-Retry-Count': '1'},
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
    final fetched = _calendarFetchedAt[value];
    if (fetched == null) return false;
    final today = _dateParam(costaRicaNow());
    final snapshot = _snapshotCache['calendar:$value'];
    final recovering =
        snapshot?.coverage?['partial'] == true || snapshot?.stale == true;
    final ttl = recovering
        ? const Duration(seconds: 20)
        : value.compareTo(today) < 0
        ? const Duration(minutes: 15)
        : value == today
        ? const Duration(seconds: 20)
        : const Duration(minutes: 5);
    return DateTime.now().toUtc().difference(fetched) < ttl;
  }

  Future<Snapshot> _fetchDate(String value) {
    return _calendarInFlight.putIfAbsent(value, () async {
      try {
        final raw = await _getJson(
          '/v1/calendar',
          queryParameters: {'date': value, 'timezone': 'America/Costa_Rica'},
        );
        final fresh = _canonical(raw);
        _remember('calendar:$value', fresh);
        _calendarFetchedAt[value] = DateTime.now().toUtc();
        await database?.saveCalendarSnapshot(value, jsonEncode(raw));
        return fresh;
      } finally {
        _calendarInFlight.remove(value);
      }
    });
  }

  @override
  Future<Snapshot> loadDate(DateTime date) => _fetchDate(_dateParam(date));

  Stream<Snapshot> watchDate(DateTime date) async* {
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
    if (cached != null) yield cached;
    if (cached != null && _freshDate(value)) return;
    try {
      yield await _fetchDate(value);
      // Only today's visible load may prefetch. Prefetch itself never recurses.
      if (value == _dateParam(costaRicaNow())) {
        unawaited(prefetchDate(date.subtract(const Duration(days: 1))));
        unawaited(prefetchDate(date.add(const Duration(days: 1))));
      }
    } catch (error, stack) {
      if (cached == null) Error.throwWithStackTrace(error, stack);
      yield cached.asStale();
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

  void refreshDate(DateTime date) =>
      _calendarFetchedAt.remove(_dateParam(date));

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

  Future<Snapshot> searchCatalog(String query, String? country) {
    final normalizedQuery = query.trim().toLowerCase();
    final normalizedCountry = country?.trim().toUpperCase() ?? '';
    return _loadSnapshot(
      'search:$normalizedCountry:$normalizedQuery',
      '/v1/search',
      queryParameters: {
        'q': query,
        if (normalizedCountry.isNotEmpty) 'country': normalizedCountry,
      },
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
    .family<Snapshot, DateTime>((ref, date) {
      final repository = ref.watch(repositoryProvider);
      if (repository is ApiRepository) return repository.watchDate(date);
      return Stream.fromFuture(repository.loadDate(date));
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

final searchSnapshotProvider =
    FutureProvider.family<Snapshot, ({String query, String? country})>((
      ref,
      request,
    ) async {
      final repository = ref.watch(repositoryProvider);
      if (repository is ApiRepository) {
        return repository.searchCatalog(request.query, request.country);
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

final matchContextSnapshotProvider = FutureProvider.autoDispose
    .family<Snapshot, String>((ref, id) async {
      final repository = ref.watch(repositoryProvider);
      if (repository is ApiRepository) {
        return repository.loadMatchContext(id);
      }
      return repository.load();
    });

final detailPollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 5),
);

final matchDetailProvider = StreamProvider.autoDispose
    .family<MatchDetail, String>((ref, id) async* {
      final repository = ref.watch(repositoryProvider);
      var disposed = false;
      Timer? timer;
      Completer<void>? waiting;
      var requestToken = CancelToken();
      final window = Stopwatch()..start();
      ref.onDispose(() {
        disposed = true;
        timer?.cancel();
        requestToken.cancel('Match Center closed');
        if (waiting != null && !waiting.isCompleted) waiting.complete();
      });
      var current = MatchDetail.waiting(id);
      yield current;
      if (disposed) return;
      try {
        current =
            await (repository is ApiRepository
                    ? repository.loadMatchDetail(id, cancelToken: requestToken)
                    : repository.loadMatchDetail(id))
                .timeout(
                  const Duration(seconds: 5),
                  onTimeout: () {
                    requestToken.cancel('Initial detail deadline');
                    throw TimeoutException('Initial detail deadline');
                  },
                );
      } catch (_) {
        // A failed read is not evidence that enrichment is absent.
        // Keep the finite pending window and try read-only cache refreshes.
        current = MatchDetail.waiting(id);
      }
      if (disposed) return;
      yield current;

      if (repository is! ApiRepository) {
        if (current.pending) {
          yield MatchDetail({...current.json, 'pending': false});
        }
        return;
      }

      for (var attempt = 0; attempt < 2 && current.pending; attempt++) {
        final remaining = const Duration(seconds: 15) - window.elapsed;
        final interval = ref.read(detailPollIntervalProvider);
        if (remaining <= interval) break;
        waiting = Completer<void>();
        timer = Timer(interval, () => waiting!.complete());
        await waiting.future;
        if (disposed) return;
        try {
          requestToken = CancelToken();
          current = await repository
              .readMatchDetail(id, cancelToken: requestToken)
              .timeout(
                const Duration(seconds: 15) - window.elapsed,
                onTimeout: () {
                  requestToken.cancel('Detail window expired');
                  throw TimeoutException('Detail window expired');
                },
              );
          if (disposed) return;
          yield current;
        } catch (_) {
          // Retain the latest detail. Never restart or extend the polling budget.
        }
      }
      if (!disposed && current.pending) {
        yield MatchDetail({...current.json, 'pending': false});
      }
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

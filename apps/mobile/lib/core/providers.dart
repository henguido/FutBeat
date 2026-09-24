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

/// Client calendar cache policy, in one place. Generic: rules depend only on
/// the distance of a date to today, never on leagues, teams or fixed dates.
class CalendarCachePolicy {
  const CalendarCachePolicy({
    this.todayTtl = const Duration(seconds: 20),
    this.pastTtl = const Duration(minutes: 5),
    this.futureTtl = const Duration(minutes: 10),
    this.recoveringTtl = const Duration(seconds: 20),
    this.prefetchRadius = 2,
    this.windowBackDays = 2,
    this.windowForwardDays = 7,
    this.receiveTimeout = const Duration(seconds: 10),
    this.visibleDeadline = const Duration(seconds: 25),
    this.maxAttempts = 3,
    this.pendingPollMin = const Duration(seconds: 2),
    this.pendingPollMax = const Duration(seconds: 8),
    this.revalidateEvery = const Duration(seconds: 30),
    this.revalidateMax = const Duration(minutes: 5),
  });

  final Duration todayTtl;
  final Duration pastTtl;
  final Duration futureTtl;

  /// Partial or stale snapshots are revalidated sooner.
  final Duration recoveringTtl;

  /// Neighbours prepared around the visible date: D+1, D-1, D+2, D-2, ...
  final int prefetchRadius;

  /// Prefetch only inside this window around today (no history cascade).
  final int windowBackDays;
  final int windowForwardDays;
  final Duration receiveTimeout;

  /// Total time a visible date may wait (requests, retries and "pending"
  /// polls). After it, the date ends in data or in an error with Retry; it is
  /// never an endless loading state.
  final Duration visibleDeadline;
  final int maxAttempts;

  /// The server may answer "pending" while it materializes a large day; the
  /// client polls on the server hint, clamped to this range.
  final Duration pendingPollMin;
  final Duration pendingPollMax;

  /// Background revalidation of a visible date that has data; doubled per
  /// consecutive failure up to [revalidateMax]. A date that never obtained a
  /// snapshot is not revalidated on a timer (the user retries).
  final Duration revalidateEvery;
  final Duration revalidateMax;

  Duration revalidateAfter(int failures) {
    final factor = 1 << (failures.clamp(0, 10));
    final delay = revalidateEvery * factor;
    return delay > revalidateMax ? revalidateMax : delay;
  }

  Duration ttl(String date, String today, {required bool recovering}) =>
      recovering
      ? recoveringTtl
      : date == today
      ? todayTtl
      : date.compareTo(today) < 0
      ? pastTtl
      : futureTtl;
}

/// One shared network request per date. Callers that pass a cancel token only
/// stop waiting; the request itself is cancelled when no waiter remains, so a
/// closed screen never cancels a prefetch (or another screen) of the same date.
class _CalendarFlight {
  final CancelToken token = CancelToken();
  late final Future<Snapshot> future;
  int _waiters = 0;
  bool _pinned = false;

  void pin() => _pinned = true;
  void join() => _waiters++;
  void leave() {
    if (--_waiters <= 0 && !_pinned && !token.isCancelled) {
      token.cancel('No calendar waiters');
    }
  }
}

class ApiRepository implements FootballRepository {
  ApiRepository(
    this.dio, [
    this.database,
    this.calendarPolicy = const CalendarCachePolicy(),
  ]);
  final Dio dio;
  final AppDatabase? database;
  final CalendarCachePolicy calendarPolicy;

  final Map<String, DateTime> _calendarFetchedAt = {};
  final Map<String, int> _calendarFailures = {};
  final Map<String, _CalendarFlight> _calendarInFlight = {};
  final Set<Future<void>> _diskWrites = {};
  Future<void> _prefetchTask = Future<void>.value();
  int _prefetchGeneration = 0;
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
    Duration? receiveTimeout,
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
            receiveTimeout:
                receiveTimeout ??
                (path == '/v1/match-detail'
                    ? const Duration(seconds: 3)
                    : null),
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
    final snapshot = _snapshotCache['calendar:$value'];
    // Partial, stale or still-live days (e.g. yesterday just after midnight)
    // revalidate on the short TTL.
    final recovering =
        snapshot?.coverage?['partial'] == true ||
        snapshot?.stale == true ||
        snapshot?.revalidating == true ||
        (snapshot?.matches.any((match) => match.isLive) ?? false);
    final ttl = calendarPolicy.ttl(
      value,
      _dateParam(costaRicaNow()),
      recovering: recovering,
    );
    return DateTime.now().toUtc().difference(fetched) < ttl;
  }

  /// Memory-only, synchronous lookup: a date switch paints the cached day in
  /// the same frame instead of flashing a loading state.
  Snapshot? peekDate(DateTime date) =>
      _snapshotCache['calendar:${_dateParam(date)}'];

  /// Waits for background prefetch and disk writes (tests and shutdown).
  Future<void> settleBackground() async {
    await _prefetchTask;
    await Future.wait([..._diskWrites]);
  }

  Future<Snapshot?> _readStored(String value) async {
    final key = 'calendar:$value';
    final memory = _snapshotCache[key];
    if (memory != null) return memory;
    try {
      final stored = await database?.readCalendarEntry(value);
      if (stored == null) return null;
      final snapshot = _canonical(jsonDecode(stored.payload) as Json);
      _remember(key, snapshot);
      _calendarFetchedAt[value] = stored.savedAt.toUtc();
      return snapshot;
    } catch (_) {
      // An unreadable/corrupt local row is replaced by the next response.
      return null;
    }
  }

  void _persist(String value, Json raw) {
    final db = database;
    if (db == null) return;
    // Never delays showing fresh data: memory already holds the snapshot.
    late final Future<void> write;
    write = db
        .saveCalendarSnapshot(value, jsonEncode(raw))
        .catchError((Object _) {})
        .whenComplete(() => _diskWrites.remove(write));
    _diskWrites.add(write);
  }

  _CalendarFlight _startFlight(String value) {
    final flight = _CalendarFlight();
    flight.future = () async {
      try {
        final raw = await _getJson(
          '/v1/calendar',
          queryParameters: {'date': value, 'timezone': 'America/Costa_Rica'},
          cancelToken: flight.token,
          maxAttempts: 1,
          receiveTimeout: calendarPolicy.receiveTimeout,
        );
        final fresh = _canonical(raw);
        // A "pending" answer (server still materializing) is never cached.
        if (fresh.calendarPending) return fresh;
        _remember('calendar:$value', fresh);
        _calendarFetchedAt[value] = DateTime.now().toUtc();
        _forcedDates.remove(value);
        _persist(value, raw);
        return fresh;
      } finally {
        if (identical(_calendarInFlight[value], flight)) {
          _calendarInFlight.remove(value);
        }
      }
    }();
    // Errors reach the waiters; an abandoned flight is never unhandled.
    unawaited(flight.future.then((_) {}, onError: (Object _) {}));
    return flight;
  }

  Future<Snapshot> _fetchDate(String value, {CancelToken? cancelToken}) {
    if (cancelToken != null && cancelToken.isCancelled) {
      return Future.error(cancelToken.cancelError!);
    }
    var flight = _calendarInFlight[value];
    if (flight == null || flight.token.isCancelled) {
      flight = _calendarInFlight[value] = _startFlight(value);
    }
    if (cancelToken == null) {
      flight.pin();
      return flight.future;
    }
    final current = flight..join();
    var joined = true;
    void leave() {
      if (!joined) return;
      joined = false;
      current.leave();
    }

    final result = Completer<Snapshot>();
    current.future.then(
      (snapshot) {
        leave();
        if (!result.isCompleted) result.complete(snapshot);
      },
      onError: (Object error, StackTrace stack) {
        leave();
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    cancelToken.whenCancel.then((error) {
      leave();
      if (!result.isCompleted) result.completeError(error);
    });
    return result.future;
  }

  @override
  Future<Snapshot> loadDate(DateTime date) => _fetchDate(_dateParam(date));

  /// Delay before revalidating a visible date that has data (backoff after
  /// consecutive failures).
  Duration calendarRevalidateDelay(DateTime date) =>
      calendarPolicy.revalidateAfter(_calendarFailures[_dateParam(date)] ?? 0);

  /// Cache first, then the network, within [CalendarCachePolicy.visibleDeadline].
  /// Terminal states: a snapshot (fresh, or the cached one marked stale) or
  /// an error when nothing was ever available. Never an endless loop.
  Stream<Snapshot> watchDate(
    DateTime date, {
    CancelToken? cancelToken,
    Duration retryDelay = const Duration(seconds: 1),
  }) async* {
    final value = _dateParam(date);
    final deadline = DateTime.now().add(calendarPolicy.visibleDeadline);
    Snapshot? cached = await _readStored(value);
    final freshCache = cached != null && _freshDate(value);
    if (cached != null) yield cached.withFreshness(revalidating: !freshCache);
    if (freshCache) {
      _prefetchAround(date);
      return;
    }
    Future<bool> wait(Duration delay) async {
      if (DateTime.now().add(delay).isAfter(deadline)) return false;
      await Future.any([
        Future<void>.delayed(delay),
        if (cancelToken != null) cancelToken.whenCancel,
      ]);
      return cancelToken?.isCancelled != true;
    }

    var failures = 0;
    var polls = 0;
    Object? lastError;
    StackTrace? lastStack;
    while (true) {
      if (cancelToken?.isCancelled == true) return;
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        lastError ??= TimeoutException(
          'Calendar date not loaded in time',
          calendarPolicy.visibleDeadline,
        );
        lastStack ??= StackTrace.current;
        break;
      }
      try {
        // The visible wait never outlives the deadline; the shared request
        // itself continues for other waiters and fills the cache.
        final snapshot = await _fetchDate(
          value,
          cancelToken: cancelToken,
        ).timeout(remaining);
        if (snapshot.calendarPending) {
          // The server is materializing this day: show the preparing state
          // (only without data) and poll on its hint, within the deadline.
          if (cached == null) yield snapshot;
          final hint = Duration(seconds: snapshot.calendarRetryAfterSeconds);
          var delay = hint * (1 << polls.clamp(0, 3));
          if (delay < calendarPolicy.pendingPollMin) {
            delay = calendarPolicy.pendingPollMin;
          }
          if (delay > calendarPolicy.pendingPollMax) {
            delay = calendarPolicy.pendingPollMax;
          }
          polls++;
          if (await wait(delay)) continue;
          if (cancelToken?.isCancelled == true) return;
          lastError = TimeoutException(
            'Calendar date is still being prepared',
            calendarPolicy.visibleDeadline,
          );
          lastStack = StackTrace.current;
          break;
        }
        _calendarFailures.remove(value);
        yield snapshot;
        _prefetchAround(date);
        return;
      } catch (error, stack) {
        if (cancelToken?.isCancelled == true) return;
        lastError = error;
        lastStack = stack;
        failures++;
        if (cached != null) yield cached.asStale();
        if (failures >= calendarPolicy.maxAttempts) break;
        if (!await wait(retryDelay * failures)) {
          if (cancelToken?.isCancelled == true) return;
          break;
        }
      }
    }
    _calendarFailures[value] = (_calendarFailures[value] ?? 0) + 1;
    if (cached != null) {
      // Keep showing the data (already marked stale after a failure);
      // background revalidation backs off.
      if (failures == 0) yield cached.asStale();
      return;
    }
    Error.throwWithStackTrace(lastError, lastStack);
  }

  /// Prepares the neighbours of the visible date one at a time (D+1, D-1,
  /// D+2, D-2, ...), only inside the window around today. A newer visible date
  /// supersedes the previous chain; missing and expired days are both fetched.
  void _prefetchAround(DateTime anchor) {
    final generation = ++_prefetchGeneration;
    final now = costaRicaNow();
    final today = DateTime.utc(now.year, now.month, now.day);
    final previous = _prefetchTask;
    _prefetchTask = () async {
      // Chains run one after another (never parallel bursts).
      await previous;
      for (var step = 1; step <= calendarPolicy.prefetchRadius; step++) {
        for (final sign in const [1, -1]) {
          if (generation != _prefetchGeneration) return;
          final day = DateTime.utc(
            anchor.year,
            anchor.month,
            anchor.day + sign * step,
          );
          final offset = day.difference(today).inDays;
          if (offset < -calendarPolicy.windowBackDays ||
              offset > calendarPolicy.windowForwardDays) {
            continue;
          }
          await prefetchDate(DateTime(day.year, day.month, day.day));
        }
      }
    }();
  }

  Future<void> prefetchDate(DateTime date) async {
    final value = _dateParam(date);
    try {
      await _readStored(value);
      if (_freshDate(value)) return;
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
    .family<Snapshot, DateTime>((ref, date) {
      // Watched synchronously so the view can peek the memory cache in the
      // first frame of a date switch.
      final repository = ref.watch(repositoryProvider);
      if (repository is! ApiRepository) {
        return Stream.fromFuture(repository.loadDate(date));
      }
      final token = CancelToken();
      Timer? timer;
      var disposed = false;
      ref.onDispose(() {
        disposed = true;
        token.cancel('Calendar date closed');
        timer?.cancel();
      });
      return () async* {
        var hasData = false;
        try {
          await for (final snapshot in repository.watchDate(
            date,
            cancelToken: token,
          )) {
            if (!snapshot.calendarPending) hasData = true;
            yield snapshot;
          }
        } finally {
          // Revalidate only a date that has data, with backoff after failures.
          // A date that never got a snapshot ends in an error with Retry: it
          // is not restarted on a timer (no endless loading loop).
          if (!disposed && hasData) {
            timer = Timer(
              repository.calendarRevalidateDelay(date),
              ref.invalidateSelf,
            );
          }
        }
      }();
      // The repository bounds its own retries (visible deadline); Riverpod's
      // automatic error retry would restart a failed date forever.
    }, retry: (_, _) => null);

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

/// Most recently opened matches kept in [matchDetailMemoryProvider].
const matchDetailMemoryLimit = 30;

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
        if (!detail.available) return;
        // Small LRU: the most recently opened matches only.
        memory
          ..remove(id)
          ..[id] = detail;
        while (memory.length > matchDetailMemoryLimit) {
          memory.remove(memory.keys.first);
        }
      }

      // Cache-first: the last good detail (if any) is shown immediately.
      var current = memory[id] ?? MatchDetail.waiting(id);
      yield current;
      if (disposed) return;
      try {
        final loaded =
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
        // Never replace remembered real data with an emptier answer.
        current = loaded.available || !current.available
            ? loaded
            : MatchDetail({...current.json, 'pending': loaded.pending});
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

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
  }) async {
    Object? lastError;
    StackTrace? lastStack;

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await dio.get<Json>(
          path,
          queryParameters: queryParameters,
          options: Options(
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
        if (attempt == 0 && _retryable(error)) {
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
      _snapshotCache.remove(_snapshotCache.keys.first);
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

  @override
  Future<Snapshot> loadDate(DateTime date) {
    final value = _dateParam(date);
    return _loadSnapshot(
      'calendar:$value',
      '/v1/calendar',
      queryParameters: {'date': value, 'timezone': 'America/Costa_Rica'},
    );
  }

  Stream<Snapshot> watchDate(DateTime date) async* {
    final value = _dateParam(date);
    final key = 'calendar:$value';
    Snapshot? cached;
    final memory = _snapshotCache[key];
    if (memory != null) {
      cached = memory;
    } else {
      final stored = await database?.readCalendarSnapshot(value);
      if (stored != null) {
        try {
          cached = _canonical(jsonDecode(stored) as Json).asStale();
          _remember(key, cached);
        } catch (_) {
          // Ignore a corrupt local row; the canonical endpoint can replace it.
        }
      }
    }
    if (cached != null) yield cached;

    try {
      final raw = await _getJson(
        '/v1/calendar',
        queryParameters: {'date': value, 'timezone': 'America/Costa_Rica'},
      );
      final fresh = _canonical(raw);
      _remember(key, fresh);
      await database?.saveCalendarSnapshot(value, jsonEncode(raw));
      yield fresh;
      unawaited(prefetchDate(date.subtract(const Duration(days: 1))));
      unawaited(prefetchDate(date.add(const Duration(days: 1))));
    } catch (error, stack) {
      if (cached == null) Error.throwWithStackTrace(error, stack);
    }
  }

  Future<void> prefetchDate(DateTime date) async {
    final value = _dateParam(date);
    if (_snapshotCache.containsKey('calendar:$value') ||
        await database?.readCalendarSnapshot(value) != null) {
      return;
    }
    try {
      final raw = await _getJson(
        '/v1/calendar',
        queryParameters: {'date': value, 'timezone': 'America/Costa_Rica'},
      );
      final snapshot = _canonical(raw);
      _remember('calendar:$value', snapshot);
      await database?.saveCalendarSnapshot(value, jsonEncode(raw));
    } catch (_) {
      // Prefetch is opportunistic and never changes the visible request.
    }
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
  Future<MatchDetail> loadMatchDetail(String id) async => MatchDetail(
    await _getJson('/v1/match-detail', queryParameters: {'id': id}),
  );

  Future<MatchDetail> readMatchDetail(String id) async => MatchDetail(
    await _getJson(
      '/v1/match-detail',
      queryParameters: {'id': id, 'request': '0'},
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

final calendarSnapshotProvider = StreamProvider.family<Snapshot, DateTime>((
  ref,
  date,
) {
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

final matchContextSnapshotProvider = FutureProvider.family<Snapshot, String>((
  ref,
  id,
) async {
  final repository = ref.watch(repositoryProvider);
  if (repository is ApiRepository) {
    return repository.loadMatchContext(id);
  }
  return repository.load();
});

final matchDetailProvider = StreamProvider.autoDispose
    .family<MatchDetail, String>((ref, id) async* {
      final repository = ref.watch(repositoryProvider);
      MatchDetail current;
      try {
        current = await repository.loadMatchDetail(id);
      } catch (_) {
        current = MatchDetail.empty(id);
      }
      yield current;

      if (repository is! ApiRepository) return;

      var delay = current.pending
          ? const Duration(seconds: 5)
          : const Duration(seconds: 30);
      for (var attempt = 0; attempt < 60; attempt++) {
        await Future<void>.delayed(delay);

        try {
          current = await repository.readMatchDetail(id);
          yield current;
        } catch (_) {
          // Keep the last known detail visible and retry on the next interval.
        }

        if (current.pending) {
          delay = const Duration(seconds: 5);
        } else {
          delay = const Duration(seconds: 30);
        }
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

final effectiveCalendarSnapshotProvider =
    Provider.family<AsyncValue<Snapshot>, DateTime>((ref, date) {
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

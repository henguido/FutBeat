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
  ApiRepository(this.dio);
  final Dio dio;

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

  @override
  Future<Snapshot> load() async =>
      _canonical((await dio.get<Json>('/v1/snapshot')).data!);

  @override
  Future<Snapshot> loadDate(DateTime date) async => _canonical(
    (
      await dio.get<Json>(
        '/v1/calendar',
        queryParameters: {
          'date': _dateParam(date),
          'timezone': 'America/Costa_Rica',
        },
      )
    ).data!,
  );

  Future<Snapshot> loadEntity(String type, String id) async => _canonical(
    (
      await dio.get<Json>(
        '/v1/entity',
        queryParameters: {'type': type, 'id': id},
      )
    ).data!,
  );

  @override
  Future<MatchDetail> loadMatchDetail(String id) async => MatchDetail(
    (
      await dio.get<Json>(
        '/v1/match-detail',
        queryParameters: {'id': id},
      )
    ).data!,
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
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
    ),
  );

  ref.onDispose(() => dio.close(force: true));
  return ApiRepository(dio);
});

final snapshotProvider = FutureProvider<Snapshot>(
  (ref) => ref.watch(repositoryProvider).load(),
);

final calendarSnapshotProvider = FutureProvider.family<Snapshot, DateTime>(
  (ref, date) => ref.watch(repositoryProvider).loadDate(date),
);


final entitySnapshotProvider =
    FutureProvider.family<Snapshot, ({String type, String id})>(
      (ref, request) async {
        final repository = ref.watch(repositoryProvider);
        if (repository is ApiRepository) {
          return repository.loadEntity(request.type, request.id);
        }
        return repository.load();
      },
    );

final matchDetailProvider =
    StreamProvider.autoDispose.family<MatchDetail, String>((ref, id) async* {
      final repository = ref.watch(repositoryProvider);
      while (true) {
        try {
          yield await repository.loadMatchDetail(id);
        } catch (_) {
          yield MatchDetail.empty(id);
        }
        await Future<void>.delayed(const Duration(seconds: 15));
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

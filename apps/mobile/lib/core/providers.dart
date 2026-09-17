import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database.dart';
import 'global_schedule.dart';
import 'live_realtime.dart';
import 'models.dart';

abstract interface class FootballRepository {
  Future<Snapshot> load();
}

class DemoRepository implements FootballRepository {
  @override
  Future<Snapshot> load() async => Snapshot(
    jsonDecode(await rootBundle.loadString('assets/demo.snapshot.json'))
        as Json,
  );
}

class ApiRepository implements FootballRepository {
  ApiRepository(this.dio);
  final Dio dio;
  @override
  Future<Snapshot> load() async {
    final snapshot = Snapshot((await dio.get<Json>('/v1/snapshot')).data!);
    if (snapshot.demo) {
      throw StateError('Cloud endpoint returned demo data');
    }
    return snapshot;
  }
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

  const browserHeaders = <String, String>{
    'accept': 'application/json,text/plain,*/*',
    'origin': 'https://www.sofascore.com',
    'referer': 'https://www.sofascore.com/',
    'user-agent':
        'Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/140.0 Mobile Safari/537.36',
  };
  final globalPrimary = Dio(
    BaseOptions(
      baseUrl: 'https://api.sofascore.com/api/v1',
      headers: browserHeaders,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
    ),
  );
  final globalFallback = Dio(
    BaseOptions(
      baseUrl: 'https://www.sofascore.com/api/v1',
      headers: browserHeaders,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
    ),
  );

  ref.onDispose(() {
    dio.close(force: true);
    globalPrimary.close(force: true);
    globalFallback.close(force: true);
  });

  final canonical = ApiRepository(dio);
  final global = GlobalScheduleRepository(
    canonical.load,
    GlobalScheduleClient(globalPrimary, globalFallback),
  );
  return _GlobalFootballRepository(global);
});

class _GlobalFootballRepository implements FootballRepository {
  _GlobalFootballRepository(this.global);

  final GlobalScheduleRepository global;

  @override
  Future<Snapshot> load() => global.load();
}

final snapshotProvider = FutureProvider<Snapshot>(
  (ref) => ref.watch(repositoryProvider).load(),
);

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

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});
final followsProvider = StreamProvider<Set<String>>(
  (ref) => ref.watch(databaseProvider).watchFollows(),
);

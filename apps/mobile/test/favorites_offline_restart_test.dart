import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/passive_preview_transport.dart';
import 'package:futbeat/core/push.dart';
import 'package:futbeat/core/sports_image_cache.dart';
import 'package:futbeat/features/favorites/favorites_screen.dart';

import 'support/install_secure_storage.dart';

const _photo = 'https://media.goal-api.com/badges/players/fixture.png';
const _keys = [
  'team:fb_team_z',
  'team:fb_team_a',
  'player:fb_player_a',
  'competition:fb_competition_a',
  'match:fb_match_a',
];
Map<String, dynamic> _catalog() => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': DateTime.now().toUtc().toIso8601String(),
  'teams': [
    {'id': 'fb_team_z', 'name': 'Zulu', 'competitionId': 'fb_competition_a'},
    {'id': 'fb_team_a', 'name': 'Alpha', 'competitionId': 'fb_competition_a'},
  ],
  'players': [
    {
      'id': 'fb_player_a',
      'name': 'Player',
      'teamId': 'fb_team_a',
      'media': {'url': _photo, 'verificationStatus': 'VERIFIED'},
    },
  ],
  'competitions': [
    {'id': 'fb_competition_a', 'name': 'Competition'},
  ],
  'matches': [
    {
      'id': 'fb_match_a',
      'homeTeamId': 'fb_team_a',
      'awayTeamId': 'fb_team_z',
      'competitionId': 'fb_competition_a',
      'status': 'SCHEDULED',
      'startTime': '2099-01-01T12:00:00Z',
      'events': [],
      'statistics': [],
    },
  ],
  'standings': [],
  'news': [
    {'unused': 'not needed offline'},
  ],
};

Dio _client({
  Map<String, dynamic>? payload,
  void Function(RequestOptions)? seen,
}) => Dio(BaseOptions(baseUrl: 'https://fixture.invalid'))
  ..interceptors.add(
    InterceptorsWrapper(
      onRequest: (r, h) {
        seen?.call(r);
        if (payload != null) {
          h.resolve(
            Response(requestOptions: r, statusCode: 200, data: payload),
          );
        } else {
          h.reject(
            DioException(
              requestOptions: r,
              type: DioExceptionType.connectionError,
            ),
          );
        }
      },
    ),
  );

class _NoPush implements PushTokenSource {
  @override
  Future<String?> currentToken() async => null;
  @override
  Future<String?> requestToken() async => null;
  @override
  Stream<String> get rotations => const Stream.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('favorites-restart-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('new SQLite and repository restore all favorites, order, aggregate and media offline', () async {
    final file = File('${root.path}/cache.sqlite');
    var db = AppDatabase(NativeDatabase(file));
    var dio = _client(payload: _catalog());
    final online = ApiRepository(dio, db);
    await db.addFollows(_keys.toSet());
    await db.saveSelectedCountry('CR');
    await db.savePreference(
      competitionOrderMode: 'manual',
      pinnedCompetitionIds: ['fb_competition_z', 'fb_competition_a'],
    );
    final first = await online.loadFavorites(_keys);
    final before = FollowingHubData.from(first, _keys.toSet());
    await online.settleBackground();
    await db.close();
    dio.close();

    db = AppDatabase(NativeDatabase(file));
    dio = _client();
    try {
      final restored = await ApiRepository(
        dio,
        db,
      ).loadFavorites(_keys.reversed.toList());
      final follows = await db.watchFollows().first;
      final hub = FollowingHubData.from(restored, follows);
      expect(restored.stale, isTrue);
      expect(follows, _keys.toSet());
      expect(hub.teams.map((e) => e.id), before.teams.map((e) => e.id));
      expect(hub.teams.map((e) => e.name), ['Alpha', 'Zulu']);
      expect(hub.players.single.id, 'fb_player_a');
      expect(hub.competitions.single.id, 'fb_competition_a');
      expect(restored.matches.single.id, 'fb_match_a');
      expect(hub.players.single.imageUrl, _photo);
      expect(
        hub.teams.first.imageUrl,
        isNull,
      ); // existing fallback, no invented image
      expect((await db.watchPreference().first).selectedCountry, 'CR');
      final preferences = await db.watchPreference().first;
      expect(preferences.competitionOrderMode, 'manual');
      expect(preferences.pinnedCompetitionIds, [
        'fb_competition_z',
        'fb_competition_a',
      ]);
      final keys = [..._keys]..sort();
      final row = await db.readPublicSnapshot(
        'public:favorites:${keys.join(',')}',
      );
      expect(row, isNotNull);
      expect(jsonDecode(row!.payload), isNot(contains('news')));
    } finally {
      dio.close();
      await db.close();
    }
  });

  test('cached superset handles removed selections without restoring removed follows', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final dio = _client(payload: _catalog());
    try {
      final online = ApiRepository(dio, db);
      await db.addFollows(_keys.toSet());
      await online.loadFavorites(_keys);
      await online.settleBackground();
      await db.removeFollows({'team:fb_team_z'});
      final follows = await db.watchFollows().first;
      final offlineDio = _client();
      try {
        final answer = await ApiRepository(
          offlineDio,
          db,
        ).loadFavorites(follows.toList());
        final hub = FollowingHubData.from(answer, follows);
        expect(hub.teams.map((e) => e.id), ['fb_team_a']);
        expect(await db.watchFollows().first, follows);
      } finally {
        offlineDio.close();
      }
    } finally {
      dio.close();
      await db.close();
    }
  });

  test('offline session restoration retains guest and never signs up another anonymous user', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final storage = InstallSecureStorage();
    storage.values['futbeat.push.session'] = jsonEncode({
      'access_token': 'synthetic-access',
      'refresh_token': 'synthetic-refresh',
      'expires_at':
          DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
          1000,
      'user': {'id': 'synthetic-guest', 'is_anonymous': true},
    });
    var signups = 0;
    final dio = _client(
      seen: (r) {
        if (r.uri.path.endsWith('/signup')) signups++;
      },
    );
    final service = PushService(
      const LiveRealtimeConfig(
        supabaseUrl: 'https://fixture.invalid',
        publicKey: 'sb_publishable_fixture',
      ),
      db,
      _NoPush(),
      dio: dio,
      secureStorage: storage,
      userSessionAccess: true,
      pushConfigured: false,
    );
    try {
      final seedDio = _client(payload: _catalog());
      final seed = ApiRepository(seedDio, db);
      await db.addFollows(_keys.toSet());
      await seed.loadFavorites(_keys);
      await seed.settleBackground();
      seedDio.close();
      await service.restore();
      await service.ensureUserSession();
      final apiDio = _client();
      apiDio.options.baseUrl =
          'https://fixture.invalid/functions/v1/futbeat-api';
      final transport = PassivePreviewTransport(
        baseUri: Uri.parse(apiDio.options.baseUrl),
        publishableKey: 'sb_publishable_fixture',
        userSession: service.apiSession,
        currentScope: () => service.userSessionScope,
        retryClient: apiDio,
      );
      apiDio.interceptors.insert(0, transport);
      try {
        final answer = await ApiRepository(apiDio, db).loadFavorites(_keys);
        expect(
          FollowingHubData.from(
            answer,
            await db.watchFollows().first,
          ).players.single.id,
          'fb_player_a',
        );
      } finally {
        transport.close();
        apiDio.close();
      }
      expect(service.userId, 'synthetic-guest');
      expect(service.isAnonymous, isTrue);
      expect(signups, 0);
      expect(
        storage.values['futbeat.push.session'],
        contains('synthetic-refresh'),
      );
    } finally {
      service.dispose();
      await service.pending;
      dio.close();
      await db.close();
    }
  });

  test('favorite image file survives a new image cache; absent image keeps fallback', () async {
    final directory = Directory('${root.path}/images');
    final png = Uint8List.fromList(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
      ),
    );
    final online = SportsImageDiskCache(
      directory: directory,
      fetch: (_) async => png,
    );
    final first = await online.resolve(canonicalId: 'fb_player_a', url: _photo);
    expect(first, isNotNull);
    final offline = SportsImageDiskCache(
      directory: directory,
      fetch: (_) async => throw const SocketException('offline'),
    );
    final stored = await offline.resolve(
      canonicalId: 'fb_player_a',
      url: _photo,
    );
    expect(await stored!.readAsBytes(), png);
    expect(
      await offline.resolve(canonicalId: 'fb_player_b', url: _photo),
      isNull,
    );
    expect(await offline.resolve(canonicalId: 'fb_team_a', url: null), isNull);
  });
  test('favorite catalog persists only public presentation and rejects foreign identities', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final raw = _catalog()
      ..addAll({
        'userId': 'synthetic-owner',
        'preferences': {'notifyGoals': false},
        'follows': _keys,
      });
    final dio = _client(payload: raw);
    final repo = ApiRepository(dio, db);
    try {
      await repo.loadFavorites(_keys);
      await repo.settleBackground();
      final key = [..._keys]..sort();
      final row = await db.readPublicSnapshot(
        'public:favorites:${key.join(',')}',
      );
      expect(row, isNotNull);
      for (final field in [
        'userId',
        'preferences',
        'follows',
        'news',
        'transfers',
      ]) {
        expect(jsonDecode(row!.payload), isNot(contains(field)));
      }
      await repo.loadFavorites(['team:fb_team_foreign']);
      await repo.settleBackground();
      expect(
        await db.readPublicSnapshot('public:favorites:team:fb_team_foreign'),
        isNull,
      );
      final offlineDio = _client();
      try {
        await expectLater(
          ApiRepository(offlineDio, db).loadFavorites(['team:fb_team_foreign']),
          throwsA(isA<DioException>()),
        );
        expect(await db.watchFollows().first, isEmpty);
      } finally {
        offlineDio.close();
      }
    } finally {
      dio.close();
      await db.close();
    }
  });

  test(
    'adding favorites online persists the new complete selection for restart',
    () async {
      final file = File('${root.path}/added.sqlite');
      var db = AppDatabase(NativeDatabase(file));
      var dio = _client(payload: _catalog());
      final repo = ApiRepository(dio, db);
      await db.addFollows({'team:fb_team_a'});
      await repo.loadFavorites(['team:fb_team_a']);
      await db.addFollows(_keys.toSet());
      await repo.loadFavorites((await db.watchFollows().first).toList());
      await repo.settleBackground();
      await db.close();
      dio.close();
      db = AppDatabase(NativeDatabase(file));
      dio = _client();
      try {
        final follows = await db.watchFollows().first;
        final data = await ApiRepository(
          dio,
          db,
        ).loadFavorites(follows.toList());
        expect(FollowingHubData.from(data, follows).teams.map((e) => e.id), [
          'fb_team_a',
          'fb_team_z',
        ]);
        expect(follows, _keys.toSet());
      } finally {
        dio.close();
        await db.close();
      }
    },
  );

  testWidgets(
    'FavoritesScreen renders SQLite favorites after restart offline',
    (tester) async {
      final file = File('${root.path}/screen.sqlite');
      await tester.runAsync(() async {
        final seedDb = AppDatabase(NativeDatabase(file));
        final seedDio = _client(payload: _catalog());
        final seed = ApiRepository(seedDio, seedDb);
        await seedDb.addFollows(_keys.toSet());
        await seed.loadFavorites(_keys);
        await seed.settleBackground();
        await seedDb.close();
        seedDio.close();
      });
      late AppDatabase db;
      await tester.runAsync(() async {
        db = AppDatabase(NativeDatabase(file));
        await db.watchFollows().first;
        await db.watchPreference().first;
      });
      final dio = _client();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          repositoryProvider.overrideWithValue(ApiRepository(dio, db)),
          liveMatchUpdatesProvider.overrideWith(
            (ref) => Stream.value(const <String, LiveMatchUpdate>{}),
          ),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        container.dispose();
        dio.close();
        await tester.runAsync(db.close);
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: FavoritesScreen()),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Zulu'), findsOneWidget);
      await tester.tap(find.text('Jugadores'));
      await tester.pumpAndSettle();
      expect(find.text('Player'), findsOneWidget);
      await tester.tap(find.text('Competiciones'));
      await tester.pumpAndSettle();
      expect(find.text('Competition'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  const stage = String.fromEnvironment('FUTBEAT_FAVORITES_RESTART_STAGE');
  const processFile = String.fromEnvironment('FUTBEAT_FAVORITES_RESTART_FILE');
  test(
    'separate OS process restores favorites and image without a network',
    () async {
      stdout.writeln('LOCAL_RESTART_STAGE=$stage TEST_PROCESS_PID=$pid');
      final file = File(processFile);
      if (stage == 'seed') expect(file.existsSync(), isFalse);
      final db = AppDatabase(NativeDatabase(file));
      final dio = _client(payload: stage == 'seed' ? _catalog() : null);
      final repo = ApiRepository(dio, db);
      final images = Directory('$processFile.images');
      final png = Uint8List.fromList(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
        ),
      );
      final cache = SportsImageDiskCache(
        directory: images,
        fetch: (_) async {
          if (stage != 'seed') throw const SocketException('offline');
          return png;
        },
      );
      try {
        if (stage == 'seed') {
          await db.addFollows(_keys.toSet());
          await db.saveSelectedCountry('CR');
        }
        final follows = await db.watchFollows().first;
        expect(follows, _keys.toSet());
        final answer = await repo.loadFavorites(follows.toList());
        final hub = FollowingHubData.from(answer, follows);
        expect(hub.teams.map((e) => e.id), ['fb_team_a', 'fb_team_z']);
        expect(hub.competitions.single.id, 'fb_competition_a');
        expect(hub.players.single.imageUrl, _photo);
        final image = await cache.resolve(
          canonicalId: hub.players.single.id,
          url: hub.players.single.imageUrl,
        );
        expect(await image!.readAsBytes(), png);
        expect((await db.watchPreference().first).selectedCountry, 'CR');
        await repo.settleBackground();
      } finally {
        dio.close();
        await db.close();
      }
    },
    skip: stage.isEmpty || processFile.isEmpty,
  );
}

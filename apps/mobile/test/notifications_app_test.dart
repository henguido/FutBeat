import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/push.dart';
import 'package:futbeat/core/push_messages.dart';
import 'package:futbeat/features/profile/notification_options.dart';
import 'package:futbeat/features/profile/profile_screen.dart';
import 'package:go_router/go_router.dart';

class _Tokens implements PushTokenSource {
  _Tokens([this.token]);
  final String? token;
  @override
  Future<String?> requestToken() async => token;

  @override
  Stream<String> get rotations => const Stream.empty();
}

/// Fake Supabase: [status] maps an RPC name to a forced HTTP error status.
class _Http {
  _Http({this.status = const {}}) {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          calls.add(options);
          final name = options.path.split('/').last;
          final forced = status[name];
          if (forced != null) {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response(
                  requestOptions: options,
                  statusCode: forced,
                  data: forced == 404
                      ? {'code': 'PGRST202', 'message': 'not found'}
                      : {'message': 'boom'},
                ),
                type: DioExceptionType.badResponse,
              ),
            );
            return;
          }
          dynamic data = <String, dynamic>{};
          if (options.path.contains('grant_type=password')) {
            data = {
              'access_token': 'access-test',
              'refresh_token': 'refresh-test',
              'user': {'id': 'user-a', 'email': 'user@example.com'},
            };
          } else if (name == 'futbeat_read_user_profile') {
            data = cloud;
          }
          handler.resolve(
            Response(requestOptions: options, statusCode: 200, data: data),
          );
        },
      ),
    );
  }

  final dio = Dio();
  final Map<String, int> status;
  Map<String, dynamic> cloud = {'preferences': null, 'follows': <dynamic>[]};
  final calls = <RequestOptions>[];

  List<RequestOptions> rpc(String name) =>
      calls.where((c) => c.path.endsWith('/rpc/$name')).toList();
}

Future<({PushService service, AppDatabase db, _Http http})> _service({
  Map<String, int> status = const {},
  bool pushConfigured = false,
  DateTime Function()? clock,
  String? token,
}) async {
  FlutterSecureStorage.setMockInitialValues({});
  final db = AppDatabase(NativeDatabase.memory());
  final http = _Http(status: status);
  final service = PushService(
    const LiveRealtimeConfig(
      supabaseUrl: 'https://supabase.test',
      publicKey: 'publishable-test-key',
    ),
    db,
    _Tokens(token),
    dio: http.dio,
    pushConfigured: pushConfigured,
    clock: clock,
  );
  return (service: service, db: db, http: http);
}

class _Messages implements PushMessageSource {
  final foregroundController = StreamController<PushMessage>.broadcast();
  final openedController = StreamController<PushMessage>.broadcast();
  PushMessage? launch;

  @override
  Stream<PushMessage> get foreground => foregroundController.stream;

  @override
  Stream<PushMessage> get opened => openedController.stream;

  @override
  Future<PushMessage?> initial() async => launch;
}

GoRouter _router({String initial = '/matches'}) => GoRouter(
  initialLocation: initial,
  routes: [
    GoRoute(
      path: '/start',
      builder: (_, _) => const Scaffold(body: Text('start')),
    ),
    GoRoute(
      path: '/matches',
      builder: (_, _) => const Scaffold(body: Text('Partidos')),
    ),
    for (final type in ['match', 'player', 'team'])
      GoRoute(
        path: '/$type/:id',
        builder: (_, state) =>
            Scaffold(body: Text('$type ${state.pathParameters['id']}')),
      ),
  ],
);

final _emptySnapshot = Snapshot({
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-09-27T00:00:00Z',
  'competitions': <dynamic>[],
  'teams': <dynamic>[],
  'players': <dynamic>[],
  'matches': <dynamic>[],
  'standings': <dynamic>[],
});

void main() {
  group('notification preferences', () {
    test('legacy payloads seed the new keys from the keys they replace', () {
      final value = UserProfileSettings.fromJson({
        'notifyCards': false,
        'notifyGoals': false,
        'notifyLineups': false,
      });
      expect(value.notifyRedCards, isFalse);
      expect(value.notifyGoalAnnulled, isFalse);
      expect(value.notifyPlayerStarter, isFalse);
      expect(value.notifyPlayerBench, isFalse);
      expect(value.notifyPlayerSubIn, isTrue);
      expect(value.notifyPlayerSubOut, isTrue);
    });

    test('snake_case server keys are read', () {
      final value = UserProfileSettings.fromJson({
        'notify_red_cards': false,
        'notify_goal_annulled': false,
        'notify_player_starter': false,
        'notify_player_bench': true,
        'notify_player_sub_in': false,
        'notify_player_sub_out': false,
      });
      expect(value.notifyRedCards, isFalse);
      expect(value.notifyCards, isTrue);
      expect(value.notifyGoalAnnulled, isFalse);
      expect(value.notifyPlayerStarter, isFalse);
      expect(value.notifyPlayerBench, isTrue);
      expect(value.notifyPlayerSubIn, isFalse);
      expect(value.notifyPlayerSubOut, isFalse);
    });

    test('local persistence round-trips every key', () {
      const value = UserProfileSettings(
        notifyRedCards: false,
        notifyGoalAnnulled: false,
        notifyPlayerStarter: false,
        notifyPlayerBench: false,
        notifyPlayerSubIn: false,
        notifyPlayerSubOut: false,
      );
      final copy = UserProfileSettings.fromJson(value.toJson());
      expect(copy.notificationPreferences, value.notificationPreferences);
      expect(value.notificationPreferences.keys, [
        ...legacyNotificationKeys,
        ...extendedNotificationKeys,
      ]);
    });

    test('red cards drive notify_cards; starter/bench drive lineups', () {
      const initial = UserProfileSettings();
      final noRed = initial.copyWith(notifyRedCards: false);
      expect(noRed.notifyRedCards, isFalse);
      expect(noRed.notifyCards, isFalse);
      final starterOnly = initial.copyWith(notifyPlayerBench: false);
      expect(starterOnly.notifyLineups, isTrue);
      final none = starterOnly.copyWith(notifyPlayerStarter: false);
      expect(none.notifyLineups, isFalse);
      expect(none.copyWith(notifyPlayerBench: true).notifyLineups, isTrue);
    });

    test('options list the approved types in order with server keys', () {
      expect(notificationOptions.map((o) => o.title), [
        'Inicio de partido',
        'Gol',
        'Gol anulado/corregido',
        'Tarjeta roja',
        'Resultado final',
        'Jugador favorito titular',
        'Jugador favorito en el banquillo',
        'Entra al campo',
        'Sale del campo',
        'Noticias',
        'Transferencias',
      ]);
      const base = UserProfileSettings();
      for (final option in notificationOptions) {
        final off = option.update(base, false);
        expect(option.value(off), isFalse, reason: option.title);
        expect(off.notificationPreferences[option.serverKey], isFalse);
      }
    });
  });

  group('profile save', () {
    test('uses the JSON RPC with every key when the server has it', () async {
      final value = await _service();
      addTearDown(() async {
        value.service.dispose();
        await value.db.close();
      });
      value.service.session = {'access_token': 'a', 'refresh_token': 'r'};
      await value.service.saveProfileSettings(
        const UserProfileSettings(displayName: 'Ana', notifyRedCards: false),
      );
      final call = value.http.rpc('futbeat_sync_user_profile_v3').single;
      final payload = (call.data as Map)['p_profile'] as Map;
      // Exactly the keys futbeat_sync_user_profile_v3 understands, all
      // switches as booleans (the server rejects anything else).
      expect(payload.keys.toSet(), {
        'displayName',
        'languageCode',
        'timezone',
        'hourFormat',
        'notifyKickoff',
        'notifyGoals',
        'notifyFinal',
        'notifyCards',
        'notifyLineups',
        'notifyNews',
        'notifyTransfers',
        'notifyRedCards',
        'notifyGoalAnnulled',
        'notifyPlayerStarter',
        'notifyPlayerBench',
        'notifyPlayerSubIn',
        'notifyPlayerSubOut',
      });
      expect(payload['displayName'], 'Ana');
      expect(payload['notifyRedCards'], isFalse);
      expect(payload['notifyCards'], isTrue);
      for (final entry in payload.entries) {
        if ('${entry.key}'.startsWith('notify')) {
          expect(entry.value, isA<bool>(), reason: '${entry.key}');
        }
      }
      expect(value.http.rpc('futbeat_sync_user_profile_v2'), isEmpty);
    });

    test('falls back to the legacy RPC (old keys) on an old server', () async {
      final value = await _service(
        status: {'futbeat_sync_user_profile_v3': 404},
      );
      addTearDown(() async {
        value.service.dispose();
        await value.db.close();
      });
      value.service.session = {'access_token': 'a', 'refresh_token': 'r'};
      final settings = const UserProfileSettings().copyWith(
        notifyRedCards: false,
      );
      await value.service.saveProfileSettings(settings);
      await value.service.saveProfileSettings(settings);

      // The missing RPC is probed once, then skipped.
      expect(value.http.rpc('futbeat_sync_user_profile_v3'), hasLength(1));
      final legacy = value.http.rpc('futbeat_sync_user_profile_v2');
      expect(legacy, hasLength(2));
      final data = legacy.first.data as Map;
      expect(data['p_notify_cards'], isFalse);
      expect(data.keys.where((k) => '$k'.startsWith('p_notify_')), [
        for (final key in legacyNotificationKeys) 'p_$key',
      ]);
      // Local persistence keeps the new keys.
      final local = await value.service.loadProfileSettings();
      expect(local.notifyRedCards, isFalse);
      expect(local.toJson().containsKey('notifyPlayerSubOut'), isTrue);
    });

    test('other server errors are surfaced, not masked by fallback', () async {
      final value = await _service(
        status: {'futbeat_sync_user_profile_v3': 500},
      );
      addTearDown(() async {
        value.service.dispose();
        await value.db.close();
      });
      value.service.session = {'access_token': 'a', 'refresh_token': 'r'};
      await expectLater(
        value.service.saveProfileSettings(const UserProfileSettings()),
        throwsA(isA<DioException>()),
      );
      expect(value.http.rpc('futbeat_sync_user_profile_v2'), isEmpty);
    });
  });

  group('account sync without push (item 4)', () {
    test(
      'sign-in creates the profile row and pushes follows with push disabled',
      () async {
        final value = await _service();
        addTearDown(() async {
          value.service.dispose();
          await value.db.close();
        });
        expect(value.service.pushConfigured, isFalse);
        await value.db.addFollows({'team:fb_1', 'player:fb_2'});
        await value.service.signIn('user@example.com', 'password-test');

        expect(value.http.rpc('futbeat_read_user_profile'), isNotEmpty);
        // No cloud preference row yet → the local profile is written.
        expect(value.http.rpc('futbeat_sync_user_profile_v3'), isNotEmpty);
        final follows = value.http.rpc('futbeat_sync_push_follows').single;
        expect(
          ((follows.data as Map)['p_follows'] as List)
              .map((f) => '${f['type']}:${f['id']}')
              .toSet(),
          {'team:fb_1', 'player:fb_2'},
        );
      },
    );

    test('a failing profile save no longer blocks the follows sync', () async {
      final value = await _service(
        status: {
          'futbeat_sync_user_profile_v3': 404,
          'futbeat_sync_user_profile_v2': 500,
        },
      );
      addTearDown(() async {
        value.service.dispose();
        await value.db.close();
      });
      await value.db.addFollows({'team:fb_1'});
      await value.service.signIn('user@example.com', 'password-test');

      expect(value.http.rpc('futbeat_sync_push_follows'), hasLength(1));
      // The profile stays dirty for the next reconcile.
      final storage = value.service.storage;
      expect(await storage.read(key: 'futbeat.profile.dirty'), isNot('false'));
    });
  });

  group('enable prompt', () {
    test('never offered when push is not configured', () async {
      final value = await _service();
      addTearDown(() async {
        value.service.dispose();
        await value.db.close();
      });
      value.service.session = {'access_token': 'a', 'refresh_token': 'r'};
      expect(await value.service.shouldPromptForNotifications(), isFalse);
    });

    test('offered once per week to a signed-in, not enabled user', () async {
      var now = DateTime.utc(2026, 10, 2);
      final value = await _service(pushConfigured: true, clock: () => now);
      addTearDown(() async {
        value.service.dispose();
        await value.db.close();
      });
      expect(await value.service.shouldPromptForNotifications(), isFalse);
      value.service.session = {'access_token': 'a', 'refresh_token': 'r'};
      expect(await value.service.shouldPromptForNotifications(), isTrue);
      await value.service.markNotificationPromptShown();
      now = now.add(const Duration(days: 6));
      expect(await value.service.shouldPromptForNotifications(), isFalse);
      now = now.add(const Duration(days: 1));
      expect(await value.service.shouldPromptForNotifications(), isTrue);
      value.service.enabled = true;
      expect(await value.service.shouldPromptForNotifications(), isFalse);
    });

    testWidgets('prompt is dismissible and not repeated', (tester) async {
      final value = await _service(pushConfigured: true);
      addTearDown(() async {
        value.service.dispose();
        await value.db.close();
      });
      value.service.session = {'access_token': 'a', 'refresh_token': 'r'};
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (c) {
                context = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      unawaited(maybeOfferNotifications(context, value.service));
      await tester.pumpAndSettle();
      expect(find.text('Activa las notificaciones'), findsOneWidget);
      await tester.tap(find.text('Ahora no'));
      await tester.pumpAndSettle();
      expect(find.text('Activa las notificaciones'), findsNothing);
      expect(value.service.enabled, isFalse);

      unawaited(maybeOfferNotifications(context, value.service));
      await tester.pumpAndSettle();
      expect(find.text('Activa las notificaciones'), findsNothing);
    });

    testWidgets('accepting enables push on this device', (tester) async {
      final value = await _service(pushConfigured: true, token: 'fcm-token');
      addTearDown(() async {
        value.service.dispose();
        await value.db.close();
      });
      value.service.session = {'access_token': 'a', 'refresh_token': 'r'};
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (c) {
                context = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      unawaited(maybeOfferNotifications(context, value.service));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Activar'));
      await tester.pumpAndSettle();
      expect(value.service.enabled, isTrue);
      final register = value.http.rpc('futbeat_register_push').single;
      expect((register.data as Map)['p_transport'], 'fcm');
      expect(find.text('Notificaciones activadas.'), findsOneWidget);
      value.service.dispose();
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });

    test('followAdded only fires for a new follow on a loaded set', () {
      expect(followAdded(null, {'team:1'}), isFalse);
      expect(followAdded(<String>{}, {'team:1'}), isTrue);
      expect(followAdded({'team:1'}, {'team:1'}), isFalse);
      expect(followAdded({'team:1', 'team:2'}, {'team:1'}), isFalse);
    });
  });

  group('push routing', () {
    test('matchId wins over playerId over teamId; ids are encoded', () {
      expect(
        pushRouteFor({'matchId': 'm1', 'playerId': 'p1', 'teamId': 't1'}),
        '/match/m1',
      );
      expect(pushRouteFor({'playerId': 'p1', 'teamId': 't1'}), '/player/p1');
      expect(pushRouteFor({'teamId': 'a/b'}), '/team/a%2Fb');
      expect(pushRouteFor({'matchId': '  '}), isNull);
      expect(pushRouteFor({'type': 'NEWS', 'articleId': 'fb_article_1'}), '/news');
    });

    testWidgets('foreground push shows a banner that opens the match', (
      tester,
    ) async {
      final source = _Messages();
      final router = _router();
      final messenger = GlobalKey<ScaffoldMessengerState>();
      final handler = PushMessageRouter(
        source: source,
        router: router,
        messenger: messenger,
      );
      addTearDown(handler.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          scaffoldMessengerKey: messenger,
        ),
      );
      handler.start();
      source.foregroundController.add(
        const PushMessage(
          title: 'Gol de Saprissa',
          body: 'Saprissa 1-0 Alajuela',
          data: {'matchId': 'fb_m_1'},
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Gol de Saprissa'), findsOneWidget);
      expect(find.text('Saprissa 1-0 Alajuela'), findsOneWidget);
      expect(find.text('Partidos'), findsOneWidget);

      await tester.tap(find.text('Ver'));
      await tester.pumpAndSettle();
      expect(find.text('match fb_m_1'), findsOneWidget);
    });

    testWidgets('tapped background push routes to the player', (tester) async {
      final source = _Messages();
      final router = _router();
      final messenger = GlobalKey<ScaffoldMessengerState>();
      final handler = PushMessageRouter(
        source: source,
        router: router,
        messenger: messenger,
      );
      addTearDown(handler.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          scaffoldMessengerKey: messenger,
        ),
      );
      handler.start();
      source.openedController.add(
        const PushMessage(data: {'playerId': 'fb_p_9'}),
      );
      await tester.pumpAndSettle();
      expect(find.text('player fb_p_9'), findsOneWidget);
    });

    testWidgets('launch push waits for the startup gate, then routes', (
      tester,
    ) async {
      final source = _Messages()
        ..launch = const PushMessage(data: {'teamId': 'fb_t_3'});
      final router = _router(initial: '/start');
      final messenger = GlobalKey<ScaffoldMessengerState>();
      final handler = PushMessageRouter(
        source: source,
        router: router,
        messenger: messenger,
      );
      addTearDown(handler.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          scaffoldMessengerKey: messenger,
        ),
      );
      handler.start();
      await tester.pumpAndSettle();
      expect(find.text('start'), findsOneWidget);

      router.go('/matches');
      await tester.pumpAndSettle();
      expect(find.text('team fb_t_3'), findsOneWidget);
    });

    test('no push source exists in builds without the push flags', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(PushService.configured, isFalse);
      expect(container.read(pushMessageSourceProvider), isNull);
    });
  });

  group('android notification channel', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final calls = <MethodCall>[];
    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(notificationsMethodChannel, (call) async {
            calls.add(call);
            return true;
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(notificationsMethodChannel, null);
    });

    test('creates futbeat_match_alerts when push is configured', () async {
      expect(
        await ensureAndroidNotificationChannel(configured: true, android: true),
        isTrue,
      );
      expect(calls.single.method, 'createNotificationChannel');
      expect(calls.single.arguments, {
        'id': 'futbeat_match_alerts',
        'name': 'Partidos',
        'description': 'Alertas de partidos y jugadores',
      });
    });

    test('does nothing without push or off Android', () async {
      expect(await ensureAndroidNotificationChannel(android: true), isFalse);
      expect(
        await ensureAndroidNotificationChannel(
          configured: true,
          android: false,
        ),
        isFalse,
      );
      expect(calls, isEmpty);
    });

    test('a missing native handler never throws', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(notificationsMethodChannel, null);
      expect(
        await ensureAndroidNotificationChannel(configured: true, android: true),
        isFalse,
      );
    });
  });

  test('v3 camelCase profile keys are adopted from the server', () async {
    final value = await _service();
    addTearDown(() async {
      value.service.dispose();
      await value.db.close();
    });
    value.http.cloud = {
      'preferences': {
        'notifyCards': false,
        'notifyRedCards': false,
        'notifyGoalAnnulled': false,
        'notifyPlayerStarter': true,
        'notifyPlayerBench': false,
        'notifyPlayerSubIn': false,
        'notifyPlayerSubOut': true,
      },
      'follows': <dynamic>[],
    };
    await value.service.signIn('user@example.com', 'password-test');
    final local = await value.service.loadProfileSettings();
    expect(local.notifyRedCards, isFalse);
    expect(local.notifyGoalAnnulled, isFalse);
    expect(local.notifyPlayerStarter, isTrue);
    expect(local.notifyPlayerBench, isFalse);
    expect(local.notifyPlayerSubIn, isFalse);
    expect(local.notifyPlayerSubOut, isTrue);
    expect(value.http.rpc('futbeat_sync_user_profile_v3'), isEmpty);
  });

  testWidgets('Perfil shows the approved alert switches in order', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final value = await _service();
    addTearDown(() async {
      value.service.dispose();
      await value.db.close();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pushServiceProvider.overrideWithValue(value.service),
          databaseProvider.overrideWithValue(value.db),
          followsProvider.overrideWith((ref) => Stream.value(<String>{})),
          preferenceProvider.overrideWith(
            (ref) => Stream.value(
              const CountryPreference(
                detectedCountry: null,
                selectedCountry: null,
                bootstrapDismissed: true,
              ),
            ),
          ),
          snapshotProvider.overrideWith((ref) async => _emptySnapshot),
          favoritesSnapshotProvider.overrideWith(
            (ref, keys) async => _emptySnapshot,
          ),
        ],
        child: const MaterialApp(home: ProfileScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    final titles = tester
        .widgetList<SwitchListTile>(find.byType(SwitchListTile))
        .map((tile) => ((tile.title as Text).data))
        .toList();
    expect(titles, notificationOptions.map((o) => o.title).toList());

    await tester.tap(find.text('Tarjeta roja'));
    await tester.pump(const Duration(milliseconds: 300));
    final saved = await value.service.loadProfileSettings();
    expect(saved.notifyRedCards, isFalse);
    expect(saved.notifyCards, isFalse);
  });
}

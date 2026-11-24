import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/notification_scopes.dart';
import 'package:futbeat/core/push.dart';
import 'package:futbeat/features/profile/notification_scopes_screen.dart';

class _Tokens implements PushTokenSource {
  @override
  Future<String?> currentToken() async => null;
  @override
  Future<String?> requestToken() async => null;
  @override
  Stream<String> get rotations => const Stream.empty();
}

class _ScopeService extends PushService {
  _ScopeService(AppDatabase db)
    : super(
        const LiveRealtimeConfig(supabaseUrl: '', publicKey: ''),
        db,
        _Tokens(),
        pushConfigured: false,
      );
  final changes = <String>[];
  @override
  Future<NotificationScopes> readNotificationScopes() async =>
      NotificationScopes.fromJson(matrix());
  @override
  Future<NotificationScopes> setNotificationScope(
    String scope,
    String kind,
    bool? enabled,
  ) async {
    changes.add('$scope:$kind:$enabled');
    return NotificationScopes.fromJson(matrix());
  }
}

Map<String, dynamic> matrix() => {
  'version': 1,
  'scopes': {
    for (final scope in notificationScopeKinds.entries)
      scope.key: {
        for (final kind in scope.value)
          kind: {'enabled': true, 'explicit': null, 'coverage': 'partial'},
      },
  },
  'unsupported': ['own_goal'],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('N1 matrix preserves scope, explicit false and provider coverage', () {
    final raw = matrix();
    raw['scopes']['team']['goal_for']['explicit'] = false;
    raw['scopes']['team']['goal_for']['enabled'] = false;
    final parsed = NotificationScopes.fromJson(raw);
    expect(parsed.scopes['team']!['goal_for']!.enabled, false);
    expect(parsed.scopes['player']!['goal']!.enabled, true);
    expect(parsed.scopes['player']!['goal']!.coverage, 'partial');
    expect(parsed.scopes['player']!.containsKey('own_goal'), false);
  });
  test('invalid matrix never becomes an enabled default', () {
    expect(() => NotificationScopes.fromJson({}), throwsFormatException);
    final raw = matrix();
    raw['scopes']['player']['goal']['enabled'] = 'true';
    expect(() => NotificationScopes.fromJson(raw), throwsFormatException);
  });

  late AppDatabase db;
  late Dio dio;
  late PushService service;
  final requests = <RequestOptions>[];
  bool offline = false;
  Completer<void>? hold;
  Completer<void>? started;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    dio = Dio();
    service = PushService(
      const LiveRealtimeConfig(
        supabaseUrl: 'https://fixture.invalid',
        publicKey: 'synthetic',
      ),
      db,
      _Tokens(),
      dio: dio,
      pushConfigured: false,
    );
    service.session = {
      'access_token': 'synthetic-A',
      'user': {'id': 'A'},
    };
    requests.clear();
    offline = false;
    hold = null;
    started = null;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (r, h) async {
          requests.add(r);
          if (hold != null) {
            started?.complete();
            await hold!.future;
          }
          if (offline) {
            h.reject(
              DioException(
                requestOptions: r,
                type: DioExceptionType.connectionError,
              ),
            );
          } else {
            h.resolve(
              Response(
                requestOptions: r,
                statusCode: 200,
                data: r.path.endsWith('futbeat-delete-account')
                    ? {'deleted': true}
                    : matrix(),
              ),
            );
          }
        },
      ),
    );
  });
  tearDown(() async {
    service.dispose();
    await db.close();
  });

  test(
    'only changed pair sent, reset null, no legacy profile or follows writes',
    () async {
      await service.setNotificationScope('team', 'goal_against', false);
      expect(requests.single.data, {
        'p_scopes': {
          'team': {'goal_against': false},
        },
      });
      await service.setNotificationScope('team', 'goal_against', null);
      expect(requests.last.data, {
        'p_scopes': {
          'team': {'goal_against': null},
        },
      });
      expect(
        requests.every(
          (r) => r.path.endsWith('futbeat_set_notification_scopes'),
        ),
        true,
      );
    },
  );
  test(
    'offline patch is durable and merges distinct pairs on reconnect',
    () async {
      offline = true;
      await expectLater(
        service.setNotificationScope('player', 'goal', false),
        throwsA(isA<DioException>()),
      );
      await expectLater(
        service.setNotificationScope('match', 'final', false),
        throwsA(isA<DioException>()),
      );
      final pending = await service.storage.read(
        key: 'futbeat.notificationScopes.pending.A',
      );
      expect(pending, contains('player'));
      service.dispose();
      final restartedDio = Dio();
      restartedDio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (r, h) {
            requests.add(r);
            h.resolve(
              Response(requestOptions: r, statusCode: 200, data: matrix()),
            );
          },
        ),
      );
      service = PushService(
        const LiveRealtimeConfig(
          supabaseUrl: 'https://fixture.invalid',
          publicKey: 'synthetic',
        ),
        db,
        _Tokens(),
        dio: restartedDio,
        pushConfigured: false,
      );
      service.session = {
        'access_token': 'synthetic-A',
        'user': {'id': 'A'},
      };
      offline = false;
      await service.readNotificationScopes();
      expect(requests[2].data, {
        'p_scopes': {
          'player': {'goal': false},
          'match': {'final': false},
        },
      });
      expect(
        await service.storage.read(key: 'futbeat.notificationScopes.pending.A'),
        null,
      );
    },
  );
  test(
    'late reply after account switch rejected and pending never sent as B',
    () async {
      hold = Completer<void>();
      started = Completer<void>();
      final operation = service.setNotificationScope('player', 'assist', false);
      final rejected = expectLater(operation, throwsStateError);
      await started!.future;
      service.session = {
        'access_token': 'synthetic-B',
        'user': {'id': 'B'},
      };
      hold!.complete();
      await rejected;
      hold = null;
      await service.readNotificationScopes();
      expect(requests.length, 2);
      expect(requests.last.path, endsWith('futbeat_read_notification_scopes'));
      expect(requests.last.headers['Authorization'], 'Bearer synthetic-B');
      expect(
        await service.storage.read(key: 'futbeat.notificationScopes.pending.A'),
        isNotNull,
      );
    },
  );
  test('unsupported personal attribution rejected before HTTP', () {
    expect(
      () => service.setNotificationScope('player', 'own_goal', true),
      throwsArgumentError,
    );
    expect(
      () => service.setNotificationScope('unknown', 'goal', true),
      throwsArgumentError,
    );
    expect(requests, isEmpty);
  });
  test('a queued scope read cannot cross into a new account after flushing', () async {
    hold = Completer<void>();
    started = Completer<void>();
    final write = service.setNotificationScope('player', 'goal', false);
    final writeRejected = expectLater(write, throwsStateError);
    await started!.future;
    final read = service.readNotificationScopes();
    final readRejected = expectLater(read, throwsStateError);
    service.session = {
      'access_token': 'synthetic-B',
      'user': {'id': 'B'},
    };
    hold!.complete();
    hold = null;
    await writeRejected;
    await readRejected;
    expect(requests.length, 1);
    expect(requests.single.headers['Authorization'], 'Bearer synthetic-A');
  });
  test(
    'all N1 catalog choices are isolated RPC patches, including lineup roles',
    () async {
      for (final scope in notificationScopeKinds.entries) {
        for (final kind in scope.value) {
          await service.setNotificationScope(scope.key, kind, false);
          expect(requests.last.data, {
            'p_scopes': {
              scope.key: {kind: false},
            },
          });
        }
      }
      expect(
        requests.every(
          (r) => r.path.endsWith('futbeat_set_notification_scopes'),
        ),
        true,
      );
    },
  );
  test(
    'latest offline choice wins without changing another follow scope',
    () async {
      offline = true;
      for (final value in [true, false, true, false]) {
        await expectLater(
          service.setNotificationScope('player', 'goal', value),
          throwsA(isA<DioException>()),
        );
      }
      await expectLater(
        service.setNotificationScope('team', 'goal_for', true),
        throwsA(isA<DioException>()),
      );
      offline = false;
      await service.readNotificationScopes();
      expect(requests[5].data, {
        'p_scopes': {
          'player': {'goal': false},
          'team': {'goal_for': true},
        },
      });
      expect(requests[6].path, endsWith('futbeat_read_notification_scopes'));
      expect(
        await service.storage.read(key: 'futbeat.notificationScopes.pending.A'),
        null,
      );
    },
  );
  test('confirmed deletion purges pending scoped preferences', () async {
    offline = true;
    await expectLater(
      service.setNotificationScope('player', 'goal', false),
      throwsA(isA<DioException>()),
    );
    offline = false;
    await service.deleteAccount();
    expect(service.authenticated, false);
    expect(
      await service.storage.read(key: 'futbeat.notificationScopes.pending.A'),
      null,
    );
  });
  testWidgets('scope UI shows coverage without unsupported promises', (
    tester,
  ) async {
    final scoped = _ScopeService(db);
    addTearDown(scoped.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [pushServiceProvider.overrideWithValue(scoped)],
        child: const MaterialApp(home: NotificationScopesScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Jugador'), findsOneWidget);
    expect(find.text('Equipo'), findsOneWidget);
    expect(find.text('Partido'), findsOneWidget);
    await tester.tap(find.text('Jugador'));
    await tester.pumpAndSettle();
    expect(find.text('Asistencia'), findsOneWidget);
    expect(find.text('Depende de los datos del proveedor'), findsWidgets);
    expect(find.text('Autogol'), findsNothing);
    final starter = find.widgetWithText(ListTile, 'Titular confirmado');
    await tester.tap(
      find.descendant(of: starter, matching: find.byType(Switch)),
    );
    await tester.pumpAndSettle();
    expect(scoped.changes, ['player:starter:false']);
    await tester.pumpWidget(const SizedBox());
  });
}

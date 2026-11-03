import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/push.dart';

class _Tokens implements PushTokenSource {
  @override
  Future<String?> currentToken() async => null;
  @override
  Future<String?> requestToken() async => null;
  @override
  Stream<String> get rotations => const Stream.empty();
}

class _ReadFault extends FlutterSecureStorage {
  bool armed = false;
  bool fired = false;
  Completer<void>? ownershipEntered;
  Completer<void>? ownershipRelease;
  Completer<void>? metadataEntered;
  Completer<void>? metadataRelease;
  int sessionDeletes = 0;
  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (key == PushService.linkedFlagKey('synthetic-account-a') &&
        metadataEntered != null &&
        !metadataEntered!.isCompleted) {
      metadataEntered!.complete();
      await metadataRelease!.future;
    }
    if (key == 'futbeat.push.session') sessionDeletes++;
    await super.delete(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (key == PushService.pushedKey('synthetic-account-a') &&
        ownershipEntered != null &&
        !ownershipEntered!.isCompleted) {
      ownershipEntered!.complete();
      await ownershipRelease!.future;
    }
    if (armed && key == PushService.pushedKey('synthetic-account-a')) {
      armed = false;
      fired = true;
      throw StateError('Synthetic single pushed-marker read failure');
    }
    return super.read(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }
}

class _Service extends PushService {
  _Service(AppDatabase db, Dio dio, this.testStorage)
    : super(
        const LiveRealtimeConfig(
          supabaseUrl: 'https://fixture.invalid',
          publicKey: 'synthetic-public',
        ),
        db,
        _Tokens(),
        dio: dio,
        pushConfigured: false,
        clock: () => DateTime.utc(2026, 11, 3, 12),
      );
  final FlutterSecureStorage testStorage;
  @override
  FlutterSecureStorage get storage => testStorage;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Real service, synthetic GoTrue/profile server, reviewed push source80228b2.
  // Direct-switch review pinned candidate blob d9d7dba67bc152a25a623cf006b3ad2fef118728.
  for (final mode in [
    'ok',
    'io',
    'io-reopen',
    'direct-signin',
    'same-account',
    'latest-intent',
    'latest-logout',
    'late-logout',
    'late-logout-c',
    'late-logout-c-fail',
    'missing',
    'invalid-json',
  ]) {
    final description = switch (mode) {
      'direct-signin' =>
        'explicit B signIn while A is authenticated keeps follows isolated',
      'same-account' =>
        'same account reauthentication retains its follows without changing B',
      'latest-intent' =>
        'newer C signIn supersedes delayed B without importing A follows',
      'latest-logout' =>
        'explicit logout supersedes B while local ownership is pending',
      'late-logout' =>
        'late logout upgrades pending switch to credential deletion',
      'late-logout-c' => 'newer C waits for late logout credential deletion',
      'late-logout-c-fail' =>
        'rejected newer C cannot falsely acknowledge disk logout',
      _ => 'A logout pushed-marker $mode is distinguished before B login',
    };
    test(description, () async {
      FlutterSecureStorage.setMockInitialValues({});
      final storage = _ReadFault();
      final directory = await Directory.systemTemp.createTemp(
        'futbeat-ownership261-',
      );
      final dbFile = File('${directory.path}/preferences.sqlite');
      var db = AppDatabase(NativeDatabase(dbFile));
      final server = <String, Set<String>>{
        'synthetic-account-a': {'team:fb_team_only_a'},
        'synthetic-account-b': {'team:fb_team_only_b'},
        'synthetic-account-c': {'team:fb_team_only_c'},
      };
      final heldB = Completer<void>();
      final releaseB = Completer<void>();
      final tokenRequests = <String>[];
      var dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              final bearer = '${request.headers['Authorization']}';
              final uid = bearer.endsWith('access-b')
                  ? 'synthetic-account-b'
                  : bearer.endsWith('access-c')
                  ? 'synthetic-account-c'
                  : 'synthetic-account-a';
              Object? result;
              if (request.path.contains('/auth/v1/token')) {
                final email = (request.data as Map)['email'];
                tokenRequests.add('$email');
                if (mode == 'late-logout-c-fail' && email == 'c@example.test') {
                  handler.reject(
                    DioException(
                      requestOptions: request,
                      response: Response(
                        requestOptions: request,
                        statusCode: 401,
                      ),
                      type: DioExceptionType.badResponse,
                    ),
                  );
                  return;
                }
                final suffix = email == 'c@example.test'
                    ? 'c'
                    : email == 'b@example.test'
                    ? 'b'
                    : 'a';
                result = {
                  'access_token': 'synthetic-access-$suffix',
                  'refresh_token': 'synthetic-refresh-$suffix',
                  'expires_at':
                      DateTime.utc(2026, 11, 3, 13).millisecondsSinceEpoch ~/
                      1000,
                  'user': {
                    'id': 'synthetic-account-$suffix',
                    'email': '$suffix@example.test',
                  },
                };
                if (mode == 'latest-intent' && suffix == 'b') {
                  heldB.complete();
                  final issued = result;
                  unawaited(
                    releaseB.future.then(
                      (_) => handler.resolve(
                        Response(
                          requestOptions: request,
                          statusCode: 200,
                          data: issued,
                        ),
                      ),
                    ),
                  );
                  return;
                }
              } else if (request.path.endsWith('futbeat_read_user_profile')) {
                result = {
                  'preferences': <String, dynamic>{},
                  'follows': [
                    for (final key in server[uid]!)
                      {
                        'type': key.split(':').first,
                        'id': key.substring(key.indexOf(':') + 1),
                      },
                  ],
                };
              } else if (request.path.endsWith('futbeat_sync_push_follows')) {
                server[uid] = {
                  for (final item in (request.data as Map)['p_follows'] as List)
                    '${item['type']}:${item['id']}',
                };
              }
              handler.resolve(
                Response(
                  requestOptions: request,
                  statusCode: 200,
                  data: result,
                ),
              );
            },
          ),
        );
      var service = _Service(db, dio, storage);
      addTearDown(() async {
        service.dispose();
        await service.pending;
        await service.signOutCleanup;
        dio.close(force: true);
        await db.close();
        await directory.delete(recursive: true);
      });
      await service.signIn('a@example.test', 'synthetic-password');
      await service.pending;
      expect(await db.watchFollows().first, contains('team:fb_team_only_a'));
      expect(
        await storage.read(key: PushService.pushedKey('synthetic-account-a')),
        isNotNull,
      );
      if (mode == 'direct-signin') {
        await service.signIn('b@example.test', 'synthetic-password');
        await service.pending;
        final local = await db.watchFollows().first;
        debugPrint(
          'AUTH261 directSignIn bConnected=${service.userId == 'synthetic-account-b'} localHasA=${local.contains('team:fb_team_only_a')} serverBHasA=${server['synthetic-account-b']!.contains('team:fb_team_only_a')}',
        );
        expect(service.userId, 'synthetic-account-b');
        expect(local, {'team:fb_team_only_b'});
        expect(server['synthetic-account-b'], {'team:fb_team_only_b'});
        expect(server['synthetic-account-a'], {'team:fb_team_only_a'});
        return;
      }
      if (mode == 'latest-logout') {
        storage.ownershipEntered = Completer<void>();
        storage.ownershipRelease = Completer<void>();
        final login = service.signIn('b@example.test', 'synthetic-password');
        await storage.ownershipEntered!.future;
        final logout = service.signOut();
        storage.ownershipRelease!.complete();
        await Future.wait([login, logout]);
        await service.pending;
        expect(service.authenticated, isFalse);
        expect(service.userId, isNull);
        expect(await storage.read(key: 'futbeat.push.session'), isNull);
        expect(server['synthetic-account-b'], {'team:fb_team_only_b'});
        return;
      }
      if (mode.startsWith('late-logout')) {
        storage.metadataEntered = Completer<void>();
        storage.metadataRelease = Completer<void>();
        final loginB = service.signIn('b@example.test', 'synthetic-password');
        await storage.metadataEntered!.future;
        final logout = service.signOut();
        Object? cError;
        final loginC = mode.startsWith('late-logout-c')
            ? service.signIn('c@example.test', 'synthetic-password').catchError(
                (Object error) {
                  cError = error;
                },
              )
            : Future<void>.value();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(tokenRequests, ['a@example.test', 'b@example.test']);
        storage.metadataRelease!.complete();
        await Future.wait([loginB, logout, loginC]);
        await service.pending;
        expect(storage.sessionDeletes, 1);
        final saved = await storage.read(key: 'futbeat.push.session');
        if (mode == 'late-logout-c') {
          expect(service.userId, 'synthetic-account-c');
          expect(jsonDecode(saved!)['user']['id'], 'synthetic-account-c');
          expect(await db.watchFollows().first, {'team:fb_team_only_c'});
        } else {
          if (mode == 'late-logout-c-fail') expect(cError, isNotNull);
          expect(service.authenticated, isFalse);
          expect(saved, isNull);
        }
        return;
      }
      if (mode == 'same-account') {
        await service.signIn('a@example.test', 'synthetic-password');
        await service.pending;
        expect(service.userId, 'synthetic-account-a');
        expect(await db.watchFollows().first, {'team:fb_team_only_a'});
        expect(server['synthetic-account-a'], {'team:fb_team_only_a'});
        expect(server['synthetic-account-b'], {'team:fb_team_only_b'});
        expect(await storage.read(key: PushService.leftoverKey), isNull);
        return;
      }
      if (mode == 'latest-intent') {
        final staleB = service.signIn('b@example.test', 'synthetic-password');
        await heldB.future;
        try {
          await service.signIn('c@example.test', 'synthetic-password');
          await service.pending;
        } finally {
          releaseB.complete();
          await staleB;
        }
        await service.pending;
        final local = await db.watchFollows().first;
        debugPrint(
          'AUTH261 latestIntent cConnected=${service.userId == 'synthetic-account-c'} localHasA=${local.contains('team:fb_team_only_a')} serverCHasA=${server['synthetic-account-c']!.contains('team:fb_team_only_a')}',
        );
        expect(service.userId, 'synthetic-account-c');
        expect(local, {'team:fb_team_only_c'});
        expect(server['synthetic-account-c'], {'team:fb_team_only_c'});
        expect(server['synthetic-account-b'], {'team:fb_team_only_b'});
        return;
      }
      if (mode.startsWith('io')) storage.armed = true;
      if (mode == 'missing') {
        await storage.delete(key: PushService.pushedKey('synthetic-account-a'));
      }
      if (mode == 'invalid-json') {
        await storage.write(
          key: PushService.pushedKey('synthetic-account-a'),
          value: '{invalid',
        );
      }
      Object? logoutError;
      try {
        await service.signOut();
      } catch (error) {
        logoutError = error;
      }
      if (mode.startsWith('io')) {
        expect(storage.fired, isTrue);
      } else {
        expect(logoutError, isNull);
      }
      final leftover = await storage.read(key: PushService.leftoverKey);
      if (mode == 'io-reopen') {
        await service.signOutCleanup;
        final handlers = dio.interceptors
            .whereType<InterceptorsWrapper>()
            .toList();
        service.dispose();
        await db.close();
        db = AppDatabase(NativeDatabase(dbFile));
        dio = Dio()..interceptors.addAll(handlers);
        service = _Service(db, dio, storage);
        await service.restore();
        // A failed close may retain A. Complete its explicit retry before
        // calling any new changes guest choices or starting B authentication.
        if (service.authenticated) {
          expect(logoutError, isNotNull);
          expect(service.userId, 'synthetic-account-a');
          debugPrint(
            'AUTH261 io-reopen closure=NOT_CONFIRMED retainedOriginalAccount=true',
          );
          await service.signOut();
          await service.signOutCleanup;
        }
        expect(service.authenticated, isFalse);
        expect(await storage.read(key: 'futbeat.push.session'), isNull);
        final durable = await storage.read(key: PushService.leftoverKey);
        expect(
          durable,
          isNotNull,
          reason: 'Guest authentication after reopening requires durable ownership of A follows',
        );
        final ownership = jsonDecode(durable!) as Map;
        expect(ownership['userId'], 'synthetic-account-a');
        expect(ownership['follows'], contains('team:fb_team_only_a'));
      }
      await db.addFollows({'team:fb_team_guest'});
      Object? loginError;
      try {
        await service.signIn('b@example.test', 'synthetic-password');
        await service.pending;
      } catch (error) {
        loginError = error;
      }
      if (mode == 'io' && service.userId != 'synthetic-account-b') {
        expect(loginError, isNotNull);
        // The same-instance snapshot of A must exclude G added after failure.
        await service.signOut();
        await service.signOutCleanup;
        await service.signIn('b@example.test', 'synthetic-password');
        await service.pending;
      }
      final local = await db.watchFollows().first;
      debugPrint(
        'AUTH261 pushedRead=$mode logoutError=${logoutError != null} leftover=${leftover != null} bConnected=${service.userId == 'synthetic-account-b'} localHasA=${local.contains('team:fb_team_only_a')} serverBHasA=${server['synthetic-account-b']!.contains('team:fb_team_only_a')}',
      );
      expect(local, contains('team:fb_team_guest'));
      if (service.userId == 'synthetic-account-b') {
        expect(server['synthetic-account-b'], contains('team:fb_team_only_b'));
        if (mode == 'ok' || mode.startsWith('io')) {
          expect(
            local,
            isNot(contains('team:fb_team_only_a')),
            reason: 'A read I/O failure must not reclassify A favourites as guest choices for B',
          );
          expect(
            server['synthetic-account-b'],
            isNot(contains('team:fb_team_only_a')),
          );
        }
      } else {
        expect(
          loginError,
          isNotNull,
          reason: 'An unresolved ownership read must fail visibly rather than importing A into B',
        );
      }
    });
  }
}

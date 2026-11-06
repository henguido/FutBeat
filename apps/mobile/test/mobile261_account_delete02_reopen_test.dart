import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/push.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/entity_media.dart';

class _Tokens implements PushTokenSource {
  @override
  Future<String?> currentToken() async => null;
  @override
  Future<String?> requestToken() async => null;
  @override
  Stream<String> get rotations => const Stream.empty();
}

class _FaultStorage extends FlutterSecureStorage {
  String? failKey;
  bool fired = false;
  final ownershipWrites = <Map<String, dynamic>>[];
  bool holdProof = false;
  bool holdProfileClear = false;
  final proofEntered = Completer<void>();
  final proofRelease = Completer<void>();
  final clearEntered = Completer<void>();
  final clearRelease = Completer<void>();
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (holdProof &&
        key == PushService.leftoverKey &&
        value != null &&
        (jsonDecode(value) as Map)['accountDeletionConfirmedFor'] == 'a') {
      holdProof = false;
      proofEntered.complete();
      await proofRelease.future;
    }
    if (holdProfileClear &&
        key == 'futbeat.profile.settings' &&
        value != null &&
        (jsonDecode(value) as Map)['displayName'] == null) {
      holdProfileClear = false;
      clearEntered.complete();
      await clearRelease.future;
    }
    if (key == failKey) {
      failKey = null;
      fired = true;
      throw StateError('Synthetic local storage IO');
    }
    await super.write(
      key: key,
      value: value,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
    if (key == PushService.leftoverKey && value != null) {
      ownershipWrites.add(Map<String, dynamic>.from(jsonDecode(value) as Map));
    }
  }
}

class _FaultSqlite extends QueryInterceptor {
  bool armed = false;
  bool fired = false;
  bool failDelete = false;
  bool deleteFired = false;
  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (failDelete && statement.toLowerCase().contains('follows')) {
      failDelete = false;
      deleteFired = true;
      throw StateError('Synthetic follow delete IO');
    }
    return executor.runDelete(statement, args);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (armed && statement.toLowerCase().contains('follows')) {
      armed = false;
      fired = true;
      throw StateError('Synthetic SQLite read IO');
    }
    return executor.runSelect(statement, args);
  }
}

class _ObservedDatabase extends AppDatabase {
  _ObservedDatabase(super.executor);
  Completer<void>? nextFollowSnapshot;
  @override
  Stream<Set<String>> watchFollows() => super.watchFollows().map((value) {
    final ready = nextFollowSnapshot;
    if (ready != null && !ready.isCompleted) ready.complete();
    return value;
  });
}

class _Service extends PushService {
  _Service(AppDatabase db, Dio dio, this.testStorage)
    : super(
        const LiveRealtimeConfig(
          supabaseUrl: 'https://fixture.invalid',
          publicKey: 'synthetic',
        ),
        db,
        _Tokens(),
        dio: dio,
        pushConfigured: false,
      );
  final FlutterSecureStorage testStorage;
  bool? firstBAcceptedAfterClear;
  final bAccepted = Completer<void>();
  @override
  set session(Map<String, dynamic>? value) {
    if (value?['user'] is Map &&
        (value!['user'] as Map)['id'] == 'b' &&
        firstBAcceptedAfterClear == null) {
      final writes = (testStorage as _FaultStorage).ownershipWrites;
      firstBAcceptedAfterClear =
          writes.isNotEmpty && writes.last['profileCleared'] == true;
      bAccepted.complete();
    }
    super.session = value;
  }

  @override
  FlutterSecureStorage get storage => testStorage;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in [
    'success',
    'profile-io',
    'provenance-io',
    'sqlite-io',
    'reselect',
    'profile-io-restart',
    'provenance-io-restart',
    'sqlite-io-restart',
    'alias-reselect',
    'intent-storage-error',
    'intent-sql-error',
    'proof-not-b',
    'restore-b',
    'profile-io-signout-restart',
    'held-rpc',
    'held-rpc-fail',
    'held-rpc-b',
    'profile-io-switch-b',
    'provenance-io-switch-b',
    'held-proof',
    'held-proof-write-io',
  ]) {
    test(
      mode == 'provenance-io-restart'
          ? 'first proof write failure is NO CONFIRMADO after crash; local recovery remains pending'
          : 'deletion preserves guest data and isolates B after retry/file reopen: $mode',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        final directory = await Directory.systemTemp.createTemp(
          'account-delete02-',
        );
        final file = File('${directory.path}/local.sqlite');
        final fault = _FaultSqlite();
        final storage = _FaultStorage();
        AppDatabase db = _ObservedDatabase(
          NativeDatabase(file).interceptWith(fault),
        );
        final server = <String, Set<String>>{
          'a': {
            'team:fb_team_only_a',
            'team:fb_team_untouched_a',
            if (mode == 'alias-reselect') 'team:fb_team_alias_a',
          },
          'b': {'team:fb_team_only_b'},
        };
        var deletions = 0;
        var refreshes = 0;
        final deletionEntered = Completer<void>();
        final releaseDeletion = Completer<void>();
        final bAuthEntered = Completer<void>();
        final releaseBAuth = Completer<void>();
        Object? heldChoiceError;
        var armFault = true;
        var failBProfile = mode == 'restore-b';
        final profiles = <String, Map<String, dynamic>>{
          'a': const UserProfileSettings(displayName: 'Account A').toJson(),
          'b': const UserProfileSettings(displayName: 'Account B').toJson(),
        };
        Dio createDio() => Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (r, h) {
                final uid = '${r.headers['Authorization']}'.endsWith('access-b')
                    ? 'b'
                    : 'a';
                Object? data;
                if (r.path.contains('/auth/v1/token')) {
                  final refresh = r.path.contains('grant_type=refresh_token');
                  if (refresh) refreshes++;
                  final body = r.data as Map;
                  final id =
                      body['email'] == 'b@example.test' ||
                          body['refresh_token'] == 'refresh-b'
                      ? 'b'
                      : 'a';
                  if (refresh && id == 'a' && deletions > 0) {
                    h.reject(
                      DioException(
                        requestOptions: r,
                        response: Response(
                          requestOptions: r,
                          statusCode: 401,
                          data: {'code': 'user_not_found'},
                        ),
                        type: DioExceptionType.badResponse,
                      ),
                    );
                    return;
                  }
                  data = {
                    'access_token': 'access-$id',
                    'refresh_token': 'refresh-$id',
                    'user': {'id': id},
                  };
                } else if (r.path.endsWith('futbeat-delete-account')) {
                  deletions++;
                  if (armFault) {
                    armFault = false;
                    if (mode.startsWith('profile-io')) {
                      storage.failKey = 'futbeat.profile.settings';
                    }
                    if (mode.startsWith('provenance-io')) {
                      storage.failKey = PushService.leftoverKey;
                    }
                    if (mode == 'held-proof-write-io') {
                      storage.failKey = PushService.leftoverKey;
                    }
                  }
                  data = {'deleted': true};
                  if (mode.startsWith('held-rpc') ||
                      mode.startsWith('held-proof')) {
                    deletionEntered.complete();
                    unawaited(
                      releaseDeletion.future.then((_) {
                        if (mode == 'held-rpc-fail') {
                          h.reject(
                            DioException(
                              requestOptions: r,
                              response: Response(
                                requestOptions: r,
                                statusCode: 503,
                              ),
                              type: DioExceptionType.badResponse,
                            ),
                          );
                        } else {
                          h.resolve(
                            Response(
                              requestOptions: r,
                              statusCode: 200,
                              data: {'deleted': true},
                            ),
                          );
                        }
                      }),
                    );
                    return;
                  }
                } else if (r.path.endsWith('futbeat_read_user_profile')) {
                  if (uid == 'b' && failBProfile) {
                    failBProfile = false;
                    storage.failKey = 'futbeat.profile.settings';
                  }
                  data = {
                    'preferences': profiles[uid],
                    'follows': [
                      for (final key in server[uid]!)
                        {
                          'type': key.split(':').first,
                          'id': key.split(':').last,
                        },
                    ],
                  };
                } else if (r.path.endsWith('futbeat_sync_push_follows')) {
                  server[uid] = {
                    for (final item in (r.data as Map)['p_follows'] as List)
                      '${item['type']}:${item['id']}',
                  };
                } else if (r.path.endsWith('futbeat_sync_user_profile_v3')) {
                  profiles[uid] = Map<String, dynamic>.from(
                    (r.data as Map)['p_profile'] as Map,
                  );
                }
                if (mode.startsWith('held-proof') &&
                    r.path.contains('/auth/v1/token') &&
                    (r.data as Map)['email'] == 'b@example.test') {
                  bAuthEntered.complete();
                  final issued = data;
                  unawaited(
                    releaseBAuth.future.then(
                      (_) => h.resolve(
                        Response(
                          requestOptions: r,
                          statusCode: 200,
                          data: issued,
                        ),
                      ),
                    ),
                  );
                  return;
                }
                h.resolve(
                  Response(requestOptions: r, statusCode: 200, data: data),
                );
              },
            ),
          );
        PushService createService(AppDatabase db, Dio dio) =>
            _Service(db, dio, storage);
        var dio = createDio();
        var service = createService(db, dio);
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
        expect(await db.watchFollows().first, server['a']);
        if (mode.startsWith('sqlite-io')) fault.armed = true;
        Object? failure;
        if (mode.startsWith('held-proof')) {
          storage.holdProof = true;
          storage.holdProfileClear = true;
        }
        final rawDeleting = service.deleteAccount();
        final deleting = mode.startsWith('held-proof')
            ? rawDeleting.then<void>(
                (_) {},
                onError: (Object error) {
                  failure = error;
                },
              )
            : rawDeleting;
        if (mode.startsWith('held-proof')) {
          await deletionEntered.future;
          final b = service.signIn('b@example.test', 'synthetic-password');
          await bAuthEntered.future;
          releaseDeletion.complete();
          await storage.proofEntered.future;
          final observedDb = db as _ObservedDatabase;
          observedDb.nextFollowSnapshot = Completer<void>();
          final leftA = service.accountChanges.firstWhere((uid) => uid == null);
          releaseBAuth.complete();
          await Future<void>.delayed(Duration.zero);
          if (service.userId == null) {
            await leftA;
            await observedDb.nextFollowSnapshot!.future;
            await Future<void>.delayed(Duration.zero);
          }
          storage.proofRelease.complete();
          await Future.any([
            storage.clearEntered.future,
            (service as _Service).bAccepted.future,
          ]);
          await Future<void>.delayed(Duration.zero);
          storage.clearRelease.complete();
          await b;
          await deleting.then(
            (_) {},
            onError: (Object error) {
              failure = error;
            },
          );
          expect(
            failure == null || failure is StateError,
            isTrue,
            reason: 'A may finish before B acceptance or report its superseded/local-write failure; B safety is asserted independently',
          );
          expect(
            service.firstBAcceptedAfterClear,
            isTrue,
            reason: 'A proof published after B preflight must be prepared before B runtime is accepted',
          );
          expect(
            storage.ownershipWrites.where(
              (record) => record['profileDisplayName'] == 'Account A',
            ),
            isEmpty,
          );
          expect(service.userId, 'b');
          await service.updateProfileSettings(
            (current) => current.copyWith(displayName: 'B later name'),
            expectedUserId: 'b',
          );
          expect(
            (await service.loadProfileSettings()).displayName,
            'B later name',
          );
          expect(deletions, 1);
          return;
        }
        if (mode.startsWith('held-rpc')) {
          await deletionEntered.future;
          if (mode == 'held-rpc-b') {
            await service.signIn('b@example.test', 'synthetic-password');
            await service.pending;
          }
          final redirects = EntityRedirectMemory();
          try {
            await toggleFollow(
              db,
              redirects,
              'team',
              mode == 'held-rpc-b'
                  ? 'fb_team_b_choice'
                  : 'fb_team_added_during_delete',
              onIntent: service.recordFollowIntent,
            );
          } catch (error) {
            heldChoiceError = error;
          }
          redirects.dispose();
          releaseDeletion.complete();
        }
        try {
          await deleting;
        } catch (error) {
          failure = error;
        }
        if (mode == 'held-rpc-b') {
          expect(failure, isA<StateError>());
          expect(
            heldChoiceError,
            isNull,
            reason: 'An old A deletion must not block B follow editing',
          );
          expect(service.userId, 'b');
          expect(await db.watchFollows().first, {
            'team:fb_team_only_b',
            'team:fb_team_b_choice',
          });
          await service.syncFollows(await db.watchFollows().first);
          expect(server['b'], {'team:fb_team_only_b', 'team:fb_team_b_choice'});
          return;
        }
        if (mode == 'held-rpc-fail') {
          expect(failure, isA<DioException>());
          expect(service.userId, 'a');
          expect(
            heldChoiceError,
            isA<StateError>(),
            reason: 'Same A writes must be blocked only while deletion is in flight',
          );
          final redirects = EntityRedirectMemory();
          await toggleFollow(
            db,
            redirects,
            'team',
            'fb_team_added_during_delete',
            onIntent: service.recordFollowIntent,
          );
          expect(
            await db.watchFollows().first,
            contains('team:fb_team_added_during_delete'),
            reason: 'Failed remote deletion must release A follow editing',
          );
          redirects.dispose();
          return;
        }
        if (mode.contains('-io')) {
          expect(
            failure,
            isNotNull,
            reason: 'Local IO failure must never acknowledge account closure',
          );
          expect(
            mode.startsWith('sqlite-io') ? fault.fired : storage.fired,
            isTrue,
          );
          expect(
            service.authenticated,
            isTrue,
            reason: 'Existing idempotent deletion remains retryable until local profile/provenance is durable',
          );
          expect(await storage.read(key: 'futbeat.push.session'), isNotNull);
          final failedMarker = await storage.read(key: PushService.leftoverKey);
          expect(
            failedMarker == null ||
                (jsonDecode(failedMarker) as Map)['profileCleared'] != true,
            isTrue,
          );
          if (mode.endsWith('-switch-b')) {
            await service.signIn('b@example.test', 'synthetic-password');
            await service.pending;
            expect(service.userId, 'b');
            expect(
              (await service.loadProfileSettings()).displayName,
              'Account B',
            );
            final redirects = EntityRedirectMemory();
            await toggleFollow(
              db,
              redirects,
              'team',
              'fb_team_b_choice',
              onIntent: service.recordFollowIntent,
            );
            redirects.dispose();
            final bFollows = await db.watchFollows().first;
            expect(bFollows, {'team:fb_team_only_b', 'team:fb_team_b_choice'});
            await service.syncFollows(bFollows);
            expect(server['b'], bFollows);
            expect(
              deletions,
              1,
              reason: 'B preparation resumes only confirmed local cleanup, never another remote delete',
            );
            expect(
              storage.ownershipWrites.where(
                (record) => record['profileDisplayName'] == 'Account A',
              ),
              isEmpty,
              reason: 'A known confirmed deleted profile must never be copied into new ownership metadata',
            );
            return;
          }
          if (!mode.endsWith('-restart')) await service.deleteAccount();
          if (mode.contains('-signout-')) {
            await service.signOut();
            await service.signOutCleanup;
            final signedOutOwner = jsonDecode(
              (await storage.read(key: PushService.leftoverKey))!,
            ) as Map;
            expect(signedOutOwner['accountDeletionConfirmedFor'], 'a');
            expect(
              signedOutOwner['profileDisplayName'],
              isNull,
              reason: 'A confirmed deleted cloud name must not be persisted by fallback logout',
            );
          }
        } else {
          expect(failure, isNull);
        }
        expect(deletions, mode == 'sqlite-io-restart' ? 0 : 1);
        if (!mode.endsWith('-restart')) expect(service.authenticated, isFalse);
        service.dispose();
        await service.pending;
        dio.close(force: true);
        await db.close();
        db = AppDatabase(NativeDatabase(file).interceptWith(fault));
        dio = createDio();
        service = createService(db, dio);
        await service.restore();
        if (mode == 'sqlite-io-restart') {
          // SQLite preflight failed BEFORE the remote irreversible operation.
          expect(service.authenticated, isTrue);
          expect(
            (await service.loadProfileSettings()).displayName,
            'Account A',
          );
          expect(deletions, 0);
          await service.deleteAccount();
          expect(deletions, 1);
        }
        expect(service.authenticated, isFalse);
        final noProofCrash = mode == 'provenance-io-restart';
        expect(
          (await service.loadProfileSettings()).displayName,
          noProofCrash ? 'Account A' : null,
          reason: noProofCrash
              ? 'NO CONFIRMADO: no durable deletion proof; 401 is not permission to erase a profile'
              : 'Confirmed local preparation must clear the deleted profile',
        );
        final marker = jsonDecode(
          (await storage.read(key: PushService.leftoverKey))!,
        ) as Map;
        if (!mode.endsWith('-restart')) {
          expect(marker['profileCleared'], isTrue);
        }
        expect(marker['profileDisplayName'], noProofCrash ? 'Account A' : null);
        if (noProofCrash) expect(marker['accountDeletionConfirmedFor'], isNull);
        expect(refreshes, noProofCrash || mode == 'sqlite-io-restart' ? 1 : 0);
        expect(
          await db.watchFollows().first,
          {
            ...server['a']!,
            if (mode == 'held-rpc' && heldChoiceError == null)
              'team:fb_team_added_during_delete',
          },
          reason: 'The deletion contract deliberately preserves local guest favourites',
        );
        await db.addFollows({'team:fb_team_guest_after_deletion'});
        if (mode == 'reselect' || mode == 'alias-reselect') {
          final redirects = EntityRedirectMemory();
          if (mode == 'alias-reselect') {
            redirects.absorb({'fb_team_alias_a': 'fb_team_only_a'});
          }
          final chosenId = mode == 'alias-reselect'
              ? 'fb_team_alias_a'
              : 'fb_team_only_a';
          await toggleFollow(
            db,
            redirects,
            'team',
            chosenId,
            onIntent: service.recordFollowIntent,
          );
          expect(
            await db.watchFollows().first,
            isNot(contains('team:fb_team_only_a')),
          );
          await toggleFollow(
            db,
            redirects,
            'team',
            chosenId,
            onIntent: service.recordFollowIntent,
          );
          expect(
            await db.watchFollows().first,
            contains('team:fb_team_only_a'),
          );
          redirects.dispose();
        }
        if (mode == 'intent-storage-error' || mode == 'intent-sql-error') {
          final before = await db.watchFollows().first;
          if (mode == 'intent-storage-error') {
            storage.failKey = PushService.leftoverKey;
          } else {
            fault.failDelete = true;
          }
          final redirects = EntityRedirectMemory();
          await expectLater(
            toggleFollow(
              db,
              redirects,
              'team',
              'fb_team_only_a',
              onIntent: service.recordFollowIntent,
            ),
            throwsStateError,
          );
          expect(
            await db.watchFollows().first,
            before,
            reason: 'Rejected SQL/intent must never claim the favourite mutation was saved',
          );
          if (mode == 'intent-sql-error') expect(fault.deleteFired, isTrue);
          redirects.dispose();
        }
        await service.signIn('b@example.test', 'synthetic-password');
        await service.pending;
        expect(await db.watchFollows().first, {
          'team:fb_team_only_b',
          'team:fb_team_guest_after_deletion',
          if (mode == 'reselect' ||
              mode == 'alias-reselect' ||
              mode == 'intent-sql-error')
            'team:fb_team_only_a',
        });
        expect(server['b'], {
          'team:fb_team_only_b',
          'team:fb_team_guest_after_deletion',
          if (mode == 'reselect' ||
              mode == 'alias-reselect' ||
              mode == 'intent-sql-error')
            'team:fb_team_only_a',
        });
        if (mode == 'restore-b') {
          expect(service.userId, 'b');
          final pendingOwner = jsonDecode(
            (await storage.read(key: PushService.leftoverKey))!,
          ) as Map;
          expect(pendingOwner['accountDeletionConfirmedFor'], 'a');
          service.dispose();
          await service.pending;
          dio.close(force: true);
          await db.close();
          db = AppDatabase(NativeDatabase(file));
          dio = createDio();
          service = createService(db, dio);
          await service.restore();
          expect(
            service.userId,
            'b',
            reason: 'An A deletion proof must not erase or reject stored B credentials',
          );
        }
        expect((await service.loadProfileSettings()).displayName, 'Account B');
        if (mode == 'held-rpc') expect(heldChoiceError, isA<StateError>());
        if (mode == 'proof-not-b') {
          await service.updateProfileSettings(
            (current) => current.copyWith(displayName: 'B custom'),
            expectedUserId: 'b',
          );
          await service.signOut();
          final bOwner = jsonDecode(
            (await storage.read(key: PushService.leftoverKey))!,
          ) as Map;
          expect(bOwner['userId'], 'b');
          expect(bOwner['accountDeletionConfirmedFor'], isNull);
          service.dispose();
          await service.pending;
          dio.close(force: true);
          await db.close();
          db = AppDatabase(NativeDatabase(file));
          dio = createDio();
          service = createService(db, dio);
          await service.restore();
          expect(service.authenticated, isFalse);
          expect(
            (await service.loadProfileSettings()).displayName,
            'B custom',
            reason: 'Ordinary B logout is not confirmed deletion of B',
          );
          expect(deletions, 1);
        }
      },
    );
  }
}

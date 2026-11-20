import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/push.dart';

import 'support/install_secure_storage.dart';

class _NoPush implements PushTokenSource {
  @override
  Future<String?> currentToken() async => null;
  @override
  Future<String?> requestToken() async =>
      throw StateError('No real push in contract test');
  @override
  Stream<String> get rotations => const Stream.empty();
}

class _AuthContract {
  final dio = Dio();
  DateTime now = DateTime.utc(2026, 11, 5, 12);
  int signups = 0, refreshes = 0, issues = 0, redeems = 0, links = 0;
  int serial = 0;
  bool offline = false, failRedeem = false;
  String? refreshFailure;
  Completer<void>? signupBarrier;
  Completer<void>? refreshBarrier;
  final refreshSeen = Completer<void>();
  String? pkceOwner;
  final signupSeen = Completer<void>();
  final accessOwners = <String, String>{};
  final refreshOwners = <String, String>{};
  final anonymous = <String, bool>{'account': false};
  final follows = <String, Set<String>>{
    'account': {'team:fb_team_account'},
  };
  final profiles = <String, Map<String, dynamic>>{
    'account': const UserProfileSettings(hourFormat: '12h').toJson(),
  };
  final countries = <String, String?>{'account': 'MX'};
  final unexpected = <String>[];
  final calls = <({String method, String path, String? uid})>[];
  String? ticketOwner;
  static final ticket = List.filled(64, 'a').join();
  Map<String, dynamic> issue(String uid, {bool? guest}) {
    if (guest != null) anonymous[uid] = guest;
    final access = 'synthetic-access-${++serial}';
    final refresh = 'synthetic-refresh-$serial';
    accessOwners[access] = uid;
    refreshOwners[refresh] = uid;
    return {
      'access_token': access,
      'refresh_token': refresh,
      'expires_in': 3600,
      'user': {
        'id': uid,
        'is_anonymous': anonymous[uid] ?? false,
        'email': anonymous[uid] == true ? null : 'account@fixture.invalid',
        'email_confirmed_at': anonymous[uid] == true
            ? null
            : '2026-11-05T00:00:00Z',
      },
    };
  }

  _AuthContract() {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) async {
          final path = request.uri.path;
          final uid =
              accessOwners['${request.headers['Authorization'] ?? ''}'
                  .replaceFirst('Bearer ', '')];
          calls.add((method: request.method, path: path, uid: uid));
          try {
            if (offline) {
              throw DioException(
                requestOptions: request,
                type: DioExceptionType.connectionError,
              );
            }
            final body = request.data is Map
                ? request.data as Map
                : const <String, dynamic>{};
            Object? data;
            if (path.endsWith('/auth/v1/signup')) {
              expect(body, isEmpty);
              expect(request.headers['apikey'], 'sb_publishable_fixture');
              signups++;
              if (!signupSeen.isCompleted) signupSeen.complete();
              await signupBarrier?.future;
              data = issue('guest-$signups', guest: true);
            } else if (path.endsWith('/auth/v1/token')) {
              if (request.uri.queryParameters['grant_type'] ==
                  'refresh_token') {
                refreshes++;
                if (!refreshSeen.isCompleted) refreshSeen.complete();
                await refreshBarrier?.future;
                if (refreshFailure != null) {
                  handler.reject(
                    DioException.badResponse(
                      statusCode: 400,
                      requestOptions: request,
                      response: Response(
                        requestOptions: request,
                        statusCode: 400,
                        data: {'error_code': refreshFailure},
                      ),
                    ),
                  );
                  return;
                }
                final owner = refreshOwners[body['refresh_token']];
                if (owner == null) throw StateError('Unexpected refresh');
                data = issue(owner);
              } else {
                data = issue(pkceOwner ?? 'account', guest: false);
              }
            } else if (path.endsWith('/auth/v1/user/identities/authorize')) {
              expect(anonymous[uid], isTrue);
              expect(request.queryParameters['skip_http_redirect'], 'true');
              expect(request.followRedirects, isFalse);
              pkceOwner = uid;
              data = {
                'url': 'https://fixture.invalid/auth/v1/authorize?flow=link',
              };
            } else if (path.endsWith('futbeat_issue_guest_merge_ticket')) {
              expect(anonymous[uid], isTrue);
              issues++;
              ticketOwner = uid;
              data = {
                'ticket': ticket,
                'expiresAt': now
                    .add(const Duration(minutes: 10))
                    .toIso8601String(),
              };
            } else if (path.endsWith('futbeat_redeem_guest_merge_ticket')) {
              expect(uid, 'account');
              expect(body['p_ticket'], ticket);
              redeems++;
              if (failRedeem) {
                handler.reject(
                  DioException.badResponse(
                    statusCode: 503,
                    requestOptions: request,
                    response: Response(
                      requestOptions: request,
                      statusCode: 503,
                    ),
                  ),
                );
                return;
              }
              follows['account']!.addAll(follows[ticketOwner] ?? {});
              data = {
                'merged': true,
                'follows': 1,
                'interests': 0,
                'preferences': 'kept',
                'devicesDisabled': 0,
              };
            } else if (path.endsWith('futbeat_read_user_profile')) {
              if (uid == null) throw StateError('No session');
              data = {
                'preferences': {
                  ...profiles.putIfAbsent(
                    uid,
                    () => const UserProfileSettings().toJson(),
                  ),
                  'selectedCountry': countries[uid],
                },
                'follows': [
                  for (final key in follows[uid] ?? <String>{})
                    {'type': key.split(':').first, 'id': key.split(':').last},
                ],
              };
            } else if (path.endsWith('futbeat_sync_push_follows')) {
              if (uid == null) throw StateError('No follow owner');
              follows[uid] = {
                for (final row in body['p_follows'] as List)
                  '${row['type']}:${row['id']}',
              };
              data = {};
            } else if (path.endsWith('futbeat_sync_user_profile_v3')) {
              profiles[uid!] = Map<String, dynamic>.from(
                body['p_profile'] as Map,
              );
              data = {};
            } else if (path.endsWith('futbeat_sync_user_preference_fields')) {
              if (body['p_update_selected'] == true) {
                countries[uid!] = body['p_selected'] as String?;
              }
              data = {};
            } else if (path.endsWith('/auth/v1/user') &&
                request.method == 'PUT') {
              expect(anonymous[uid], isTrue);
              links++;
              data = {'id': uid, 'is_anonymous': true, 'email': body['email']};
            } else if (path.endsWith('/auth/v1/logout')) {
              data = {};
            } else {
              unexpected.add('$path:${request.method}');
              throw StateError('Unexpected contract request');
            }
            handler.resolve(
              Response(requestOptions: request, statusCode: 200, data: data),
            );
          } on DioException catch (error) {
            handler.reject(error);
          } catch (error) {
            handler.reject(DioException(requestOptions: request, error: error));
          }
        },
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _AuthContract server;
  late AppDatabase db;
  late InstallSecureStorage storage;
  late PushService service;
  PushService create() => PushService(
    const LiveRealtimeConfig(
      supabaseUrl: 'https://fixture.invalid',
      publicKey: 'sb_publishable_fixture',
    ),
    db,
    _NoPush(),
    dio: server.dio,
    secureStorage: storage,
    userSessionAccess: true,
    pushConfigured: false,
    clock: () => server.now,
  );
  Future<void> settle() async {
    await service.pending;
    await service.countryPending;
  }

  setUp(() {
    server = _AuthContract();
    db = AppDatabase(NativeDatabase.memory());
    storage = InstallSecureStorage();
    service = create();
  });
  tearDown(() async {
    await settle();
    service.dispose();
    await db.close();
    expect(server.unexpected, isEmpty);
  });

  test('first start bootstraps one anonymous session for concurrent readers and normalizes expiry', () async {
    server.signupBarrier = Completer<void>();
    final a = service.ensureUserSession();
    final b = service.ensureUserSession();
    await server.signupSeen.future;
    expect(server.signups, 1);
    server.signupBarrier!.complete();
    await Future.wait([a, b]);
    expect(service.isAnonymous, isTrue);
    expect(service.registered, isFalse);
    expect(
      service.session!['expires_at'],
      server.now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
    );
    await service.ensureUserSession();
    expect(server.signups, 1);
    expect(server.refreshes, 0);
    expect(
      jsonDecode(storage.values['futbeat.push.session']!)['user']['id'],
      'guest-1',
    );
  });

  test('restart restores and refreshes the same guest instead of creating a new one', () async {
    storage.values['futbeat.push.session'] = jsonEncode(
      server.issue('existing', guest: true),
    );
    await service.ensureUserSession();
    expect(service.userId, 'existing');
    expect(server.signups, 0);
    expect(server.refreshes, 1);
  });

  test('offline refresh keeps tokens and local favourites and never creates another guest', () async {
    final saved = server.issue('existing', guest: true)
      ..['expires_at'] =
          server.now
              .subtract(const Duration(minutes: 2))
              .millisecondsSinceEpoch ~/
          1000;
    storage.values['futbeat.push.session'] = jsonEncode(saved);
    await db.addFollows({'team:fb_team_local'});
    server.offline = true;
    await service.restore();
    expect(service.userId, 'existing');
    expect(storage.values['futbeat.push.session'], jsonEncode(saved));
    await expectLater(service.apiSession(), throwsA(isA<DioException>()));
    expect(server.signups, 0);
    expect(await db.watchFollows().first, {'team:fb_team_local'});
  });

  test(
    'failed bootstrap backs off instead of creating guests on every read',
    () async {
      server.offline = true;
      await expectLater(
        service.ensureUserSession(),
        throwsA(isA<DioException>()),
      );
      final count = server.calls.length;
      await service.ensureUserSession();
      await service.ensureUserSession();
      expect(server.calls.length, count);
      expect(service.authenticated, isFalse);
    },
  );

  test(
    'only definitive refresh-token rejection allows replacement guest',
    () async {
      storage.values['futbeat.push.session'] = jsonEncode(
        server.issue('expired', guest: true),
      );
      server.refreshFailure = 'refresh_token_not_found';
      await service.ensureUserSession();
      expect(service.userId, 'guest-1');
      expect(server.signups, 1);
    },
  );

  test(
    'other 401/400 errors do not erase the existing refresh identity',
    () async {
      storage.values['futbeat.push.session'] = jsonEncode(
        server.issue('existing', guest: true),
      );
      server.refreshFailure = 'bad_jwt';
      await service.ensureUserSession();
      expect(service.userId, 'existing');
      expect(server.signups, 0);
    },
  );

  for (final onRejectedRequest in [false, true]) {
    test(
      'late rejected guest refresh preserves the newer account (401=$onRejectedRequest)',
      () async {
        await service.ensureUserSession();
        await settle();
        final rejected = service.session!['access_token'] as String;
        if (!onRejectedRequest) {
          service.session!['expires_at'] =
              server.now.millisecondsSinceEpoch ~/ 1000 - 1;
        }
        server.refreshBarrier = Completer<void>();
        server.refreshFailure = 'refresh_token_already_used';
        final operation = onRejectedRequest
            ? service.apiSession(rejectedToken: rejected).then<void>((_) {})
            : service.ensureUserSession();
        // A stale refresh may fail to its original caller; it cannot log out B.
        final observed = operation.catchError((_) {});
        await server.refreshSeen.future;
        await service.signIn('account@fixture.invalid', 'synthetic-password');
        await settle();
        expect(service.userId, 'account');
        server.refreshBarrier!.complete();
        await observed;
        await settle();
        expect(service.userId, 'account');
        expect(service.registered, isTrue);
        expect(await db.watchFollows().first, contains('team:fb_team_account'));
        expect(server.signups, 1);
      },
    );
  }

  for (final fallback in [false, true]) {
    test(
      'guest login uses ticket and keeps account preferences (fallback=$fallback)',
      () async {
        await service.ensureUserSession();
        await settle();
        await db.addFollows({'team:fb_team_guest'});
        await service.saveProfileSettings(
          const UserProfileSettings(hourFormat: '24h', notifyGoals: false),
        );
        await db.saveSelectedCountry('CR');
        await service.markSelectedCountryDirty();
        await settle();
        server.failRedeem = fallback;
        await service.signIn('account@fixture.invalid', 'synthetic-password');
        await settle();
        expect(server.issues, 1);
        expect(server.redeems, 1);
        expect(service.registered, isTrue);
        expect(
          await db.watchFollows().first,
          containsAll({'team:fb_team_guest', 'team:fb_team_account'}),
        );
        expect((await service.loadProfileSettings()).notifyGoals, isTrue);
        expect((await service.loadProfileSettings()).hourFormat, '12h');
        expect((await db.watchPreference().first).selectedCountry, 'MX');
        expect(
          storage.values.values.any(
            (value) => value.contains(_AuthContract.ticket),
          ),
          isFalse,
        );
      },
    );
  }

  test(
    'email signup links the same guest ID without an additional signup',
    () async {
      await service.ensureUserSession();
      final uid = service.userId;
      await db.addFollows({'team:fb_team_guest'});
      await settle();
      await service.signUp('new@fixture.invalid', 'synthetic-password');
      expect(service.userId, uid);
      expect(service.isAnonymous, isTrue);
      expect(service.pendingConfirmationEmail, 'new@fixture.invalid');
      expect(server.signups, 1);
      expect(server.links, 1);
      expect(server.issues, 0);
      expect(await db.watchFollows().first, contains('team:fb_team_guest'));
    },
  );

  test('concurrent 401 refresh callers share one token rotation', () async {
    await service.ensureUserSession();
    final old = service.session!['access_token'] as String;
    server.refreshBarrier = Completer<void>();
    final first = service.apiSession(rejectedToken: old);
    final second = service.apiSession(rejectedToken: old);
    await server.refreshSeen.future;
    expect(server.refreshes, 1);
    server.refreshBarrier!.complete();
    final answers = await Future.wait([first, second]);
    expect(answers[0]!.accessToken, answers[1]!.accessToken);
    expect(answers[0]!.accessToken, isNot(old));
    expect(server.signups, 1);
  });

  test(
    'Google creation links PKCE to the same guest without a merge ticket',
    () async {
      service.dispose();
      server = _AuthContract();
      service = PushService(
        const LiveRealtimeConfig(
          supabaseUrl: 'https://fixture.invalid',
          publicKey: 'sb_publishable_fixture',
        ),
        db,
        _NoPush(),
        dio: server.dio,
        secureStorage: storage,
        userSessionAccess: true,
        pushConfigured: false,
        clock: () => server.now,
        oauthEnabled: true,
        oauthAllowedProviders: const {OAuthProvider.google},
        oauthBrowser: (uri, scheme) async {
          expect(uri.scheme, 'https');
          expect(uri.toString(), isNot(contains('synthetic-access')));
          return 'com.futbeat.futbeat://login-callback?code=synthetic-code';
        },
      );
      await service.ensureUserSession();
      final uid = service.userId;
      await db.addFollows({'team:fb_team_guest'});
      await settle();
      await service.linkAnonymousIdentity(OAuthProvider.google);
      await settle();
      expect(service.userId, uid);
      expect(service.registered, isTrue);
      expect(server.signups, 1);
      expect(server.issues, 0);
      expect(await db.watchFollows().first, contains('team:fb_team_guest'));
    },
  );

  test(
    'a secure-storage failure retries persistence, never guest creation',
    () async {
      storage.failWriteKey = 'futbeat.push.session';
      await expectLater(service.ensureUserSession(), throwsStateError);
      expect(service.isAnonymous, isTrue);
      final uid = service.userId;
      await service.ensureUserSession();
      expect(server.signups, 1);
      expect(service.userId, uid);
      expect(
        jsonDecode(storage.values['futbeat.push.session']!)['user']['id'],
        uid,
      );
    },
  );

  test('a late guest bootstrap cannot replace an explicit sign-in', () async {
    server.signupBarrier = Completer<void>();
    final guest = service.ensureUserSession();
    await server.signupSeen.future;
    await service.signIn('account@fixture.invalid', 'synthetic-password');
    expect(service.userId, 'account');
    server.signupBarrier!.complete();
    await guest;
    expect(service.userId, 'account');
    expect(server.signups, 1);
    expect(
      jsonDecode(storage.values['futbeat.push.session']!)['user']['id'],
      'account',
    );
  });

  test(
    'direct account switch cannot carry the previous account preferences',
    () async {
      server.anonymous['first'] = false;
      server.follows['first'] = {'team:fb_team_first'};
      server.profiles['first'] = const UserProfileSettings(
        hourFormat: '24h',
        notifyGoals: false,
      ).toJson();
      server.countries['first'] = 'CR';
      storage.values['futbeat.push.session'] = jsonEncode(
        server.issue('first', guest: false),
      );
      await service.ensureUserSession();
      await settle();
      await service.signIn('account@fixture.invalid', 'synthetic-password');
      await settle();
      expect(service.userId, 'account');
      expect(await db.watchFollows().first, {'team:fb_team_account'});
      expect((await service.loadProfileSettings()).notifyGoals, isTrue);
      expect((await db.watchPreference().first).selectedCountry, 'MX');
    },
  );

  test(
    'logout hides account-owned data before provisioning a new guest',
    () async {
      await service.ensureUserSession();
      await service.signIn('account@fixture.invalid', 'synthetic-password');
      await settle();
      expect(await db.watchFollows().first, contains('team:fb_team_account'));
      await service.signOut();
      await service.ensureUserSession();
      await settle();
      expect(service.isAnonymous, isTrue);
      expect(service.userId, isNot('account'));
      expect(await db.watchFollows().first, isEmpty);
      expect((await db.watchPreference().first).selectedCountry, isNull);
      expect((await service.loadProfileSettings()).displayName, isNull);
      expect(server.follows['account'], contains('team:fb_team_account'));
    },
  );
}

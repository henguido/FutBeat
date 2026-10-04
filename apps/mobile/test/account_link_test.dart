import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/push.dart';

const _config = LiveRealtimeConfig(
  supabaseUrl: 'https://supabase.test',
  publicKey: 'publishable-test-key',
);

class _Tokens implements PushTokenSource {
  @override
  Future<String?> requestToken() async => null;

  @override
  Stream<String> get rotations => const Stream.empty();
}

/// Server defaults of a brand-new `user_preferences` row, exactly what
/// `futbeat_read_user_profile` returns on an account's first read (it
/// inserts the row).
Map<String, dynamic> _defaultRow() => {
  'detectedCountry': null,
  'selectedCountry': null,
  'displayName': null,
  'languageCode': 'es',
  'timezone': 'America/Costa_Rica',
  'hourFormat': 'system',
  'notifyKickoff': true,
  'notifyGoals': true,
  'notifyFinal': true,
  'notifyCards': true,
  'notifyLineups': true,
  'notifyNews': true,
  'notifyTransfers': true,
  'updatedAt': '2026-10-04T22:10:04Z',
};

/// GoTrue + PostgREST fake with per-user server state.
class _Server {
  _Server() {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final path = options.uri.toString();
          final uid = _caller(options);
          Object? data = <String, dynamic>{};
          if (path.contains('grant_type=password') ||
              path.contains('grant_type=pkce') ||
              path.contains('grant_type=refresh_token')) {
            final email = options.data is Map
                ? (options.data as Map)['email']?.toString()
                : null;
            data = _session(
              email == null ? nextUser : email.substring(0, email.indexOf('@')),
            );
          } else if (path.contains('/auth/v1/logout')) {
            data = null;
          } else if (path.contains('futbeat_read_user_profile')) {
            final prefs = preferences.putIfAbsent(uid!, _defaultRow);
            data = {
              'preferences': Map<String, dynamic>.from(prefs),
              'follows': [
                for (final key in follows[uid] ?? const <String>{})
                  {
                    'type': key.substring(0, key.indexOf(':')),
                    'id': key.substring(key.indexOf(':') + 1),
                  },
              ],
            };
          } else if (path.contains('futbeat_sync_push_follows')) {
            follows[uid!] = {
              for (final item in (options.data as Map)['p_follows'] as List)
                '${item['type']}:${item['id']}',
            };
          } else if (path.contains('futbeat_sync_user_profile_v3')) {
            preferences[uid!] = {
              ...preferences[uid] ?? _defaultRow(),
              ...(options.data as Map)['p_profile'] as Map<String, dynamic>,
            };
          } else if (path.contains('futbeat_sync_user_preference_fields')) {
            final body = options.data as Map;
            final row = preferences[uid!] ??= _defaultRow();
            if (body['p_update_detected'] == true) {
              row['detectedCountry'] = body['p_detected'];
            }
            if (body['p_update_selected'] == true) {
              row['selectedCountry'] = body['p_selected'];
            }
          }
          handler.resolve(
            Response(requestOptions: options, statusCode: 200, data: data),
          );
        },
      ),
    );
  }

  final dio = Dio();
  String nextUser = 'user-g';
  final follows = <String, Set<String>>{};
  final preferences = <String, Map<String, dynamic>>{};

  static String? _caller(RequestOptions options) {
    final bearer = '${options.headers['Authorization'] ?? ''}';
    return bearer.startsWith('Bearer access-')
        ? bearer.substring('Bearer access-'.length)
        : null;
  }

  static Map<String, dynamic> _session(String uid) => {
    'access_token': 'access-$uid',
    'refresh_token': 'refresh-$uid',
    'expires_at':
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
        1000,
    'user': {
      'id': uid,
      'email': '$uid@example.com',
      'email_confirmed_at': '2026-10-04T00:00:00Z',
      'app_metadata': {'provider': 'google'},
    },
  };
}

void main() {
  late AppDatabase db;
  late _Server server;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    server = _Server();
  });
  tearDown(() => db.close());

  PushService service() {
    final value = PushService(
      _config,
      db,
      _Tokens(),
      dio: server.dio,
      oauthEnabled: true,
      oauthBrowser: (_, _) async =>
          'com.futbeat.futbeat://login-callback?code=one-time',
    );
    addTearDown(value.dispose);
    return value;
  }

  /// A guest that set everything up before signing in, through the same
  /// calls the onboarding / Perfil make.
  Future<void> guestSetup(PushService value) async {
    await db.savePreference(detectedCountry: 'CR', selectedCountry: null);
    await value.markDetectedCountryDirty();
    await db.saveSelectedCountry('CR');
    await value.markSelectedCountryDirty();
    await db.addFollows({
      'team:team_cr',
      'team:team_es',
      'competition:competition_cr',
      'player:player_cr',
    });
    await value.saveProfileSettings(
      const UserProfileSettings(
        hourFormat: '24h',
        notifyGoals: false,
        notifyTransfers: false,
      ),
    );
  }

  for (final (name, signIn) in [
    (
      'Google (PKCE)',
      (PushService s) => s.signInWithOAuth(OAuthProvider.google),
    ),
    ('email', (PushService s) => s.signIn('user-g@example.com', 'secreta-1')),
  ]) {
    test(
      '$name first link keeps every guest choice, local and server',
      () async {
        final value = service();
        await guestSetup(value);
        await signIn(value);

        final follows = await db.watchFollows().first;
        expect(follows, {
          'team:team_cr',
          'team:team_es',
          'competition:competition_cr',
          'player:player_cr',
        });
        expect(server.follows['user-g'], follows);
        final local = await value.loadProfileSettings();
        expect(local.hourFormat, '24h');
        expect(local.notifyGoals, isFalse);
        expect(local.notifyTransfers, isFalse);
        expect(server.preferences['user-g']!['hourFormat'], '24h');
        final preference = await db.watchPreference().first;
        expect(preference.selectedCountry, 'CR');
        expect(server.preferences['user-g']!['selectedCountry'], 'CR');
      },
    );
  }

  Future<void> loseDirtyFlags() async {
    const storage = FlutterSecureStorage();
    for (final key in const [
      'futbeat.profile.dirty',
      'futbeat.country.dirty',
      'futbeat.country.detected.dirty',
      'futbeat.country.selected.dirty',
    ]) {
      await storage.delete(key: key);
    }
  }

  test(
    'lost dirty flags: server defaults never overwrite guest choices',
    () async {
      final value = service();
      await guestSetup(value);
      await loseDirtyFlags();
      await value.signInWithOAuth(OAuthProvider.google);

      final local = await value.loadProfileSettings();
      expect(local.hourFormat, '24h');
      expect(local.notifyGoals, isFalse);
      expect(local.notifyTransfers, isFalse);
      expect((await db.watchPreference().first).selectedCountry, 'CR');
      expect(server.preferences['user-g']!['hourFormat'], '24h');
      expect(server.preferences['user-g']!['notifyGoals'], isFalse);
      expect(server.preferences['user-g']!['selectedCountry'], 'CR');
      expect(server.preferences['user-g']!['detectedCountry'], 'CR');
      expect(server.follows['user-g'], hasLength(4));
    },
  );

  test('guest A,B + account B,C: A,B,C on both sides, no duplicates', () async {
    server.follows['user-g'] = {'team:b', 'team:c'};
    server.preferences['user-g'] = _defaultRow();
    final value = service();
    await db.addFollows({'team:a', 'team:b'});
    await value.signInWithOAuth(OAuthProvider.google);
    expect(await db.watchFollows().first, {'team:a', 'team:b', 'team:c'});
    expect(server.follows['user-g'], {'team:a', 'team:b', 'team:c'});
  });

  test('an explicit account preference wins over a local default', () async {
    server.preferences['user-g'] = {
      ..._defaultRow(),
      'hourFormat': '12h',
      'notifyKickoff': false,
      'selectedCountry': 'ES',
    };
    final value = service();
    await value.signInWithOAuth(OAuthProvider.google);
    final local = await value.loadProfileSettings();
    expect(local.hourFormat, '12h');
    expect(local.notifyKickoff, isFalse);
    expect((await db.watchPreference().first).selectedCountry, 'ES');
  });

  test('a manual guest country beats the account country', () async {
    server.preferences['user-g'] = {..._defaultRow(), 'selectedCountry': 'ES'};
    final value = service();
    await db.saveSelectedCountry('CR');
    await value.markSelectedCountryDirty();
    await value.signInWithOAuth(OAuthProvider.google);
    expect((await db.watchPreference().first).selectedCountry, 'CR');
    expect(server.preferences['user-g']!['selectedCountry'], 'CR');
  });

  test('restart after login keeps follows and settings', () async {
    final first = service();
    await guestSetup(first);
    await first.signInWithOAuth(OAuthProvider.google);
    first.dispose();

    final restarted = service();
    await restarted.restore();
    expect(restarted.authenticated, isTrue);
    expect(await db.watchFollows().first, hasLength(4));
    final local = await restarted.loadProfileSettings();
    expect(local.hourFormat, '24h');
    expect(local.notifyGoals, isFalse);
    expect((await db.watchPreference().first).selectedCountry, 'CR');
    expect(server.follows['user-g'], hasLength(4));
    expect(server.preferences['user-g']!['hourFormat'], '24h');
  });

  test(
    'account A, sign out, account B: A never leaks; later guest adds do',
    () async {
      final value = service();
      await db.addFollows({'team:a1', 'team:a2'});
      await value.signIn('user-a@example.com', 'secreta-1');
      expect(server.follows['user-a'], {'team:a1', 'team:a2'});
      await value.signOut();
      await value.signOutCleanup;
      // Guest after sign-out adds one follow on purpose.
      await db.addFollows({'team:guest'});
      await value.signIn('user-b@example.com', 'secreta-1');
      expect(server.follows['user-b'], {'team:guest'});
      expect(await db.watchFollows().first, {'team:guest'});
    },
  );

  test('the UI hears the profile change made by the link', () async {
    server.preferences['user-g'] = {..._defaultRow(), 'hourFormat': '12h'};
    final value = service();
    var changes = 0;
    final sub = value.profileChanges.listen((_) => changes++);
    addTearDown(sub.cancel);
    await value.signInWithOAuth(OAuthProvider.google);
    await Future<void>.delayed(Duration.zero);
    expect(changes, greaterThan(0));
  });

  group('mergeFirstLinkProfile', () {
    test('server defaults keep local; explicit server wins unless edited', () {
      const local = UserProfileSettings(hourFormat: '24h', notifyNews: false);
      const cloud = UserProfileSettings(hourFormat: '12h');
      expect(
        mergeFirstLinkProfile(
          local: local,
          cloud: cloud,
          localEdited: true,
        ).hourFormat,
        '24h',
      );
      expect(
        mergeFirstLinkProfile(
          local: local,
          cloud: cloud,
          localEdited: false,
        ).hourFormat,
        '12h',
      );
      final keep = mergeFirstLinkProfile(
        local: local,
        cloud: const UserProfileSettings(timezone: 'America/Costa_Rica'),
        localEdited: false,
      );
      expect(keep.notifyNews, isFalse);
      expect(keep.timezone, 'device');
    });

    test(
      'country: manual local, else explicit cloud, never null over local',
      () {
        expect(
          mergeFirstLinkCountry(local: 'CR', cloud: 'ES', localManual: true),
          'CR',
        );
        expect(
          mergeFirstLinkCountry(local: 'CR', cloud: 'ES', localManual: false),
          'ES',
        );
        expect(
          mergeFirstLinkCountry(local: 'CR', cloud: null, localManual: false),
          'CR',
        );
      },
    );
  });
}

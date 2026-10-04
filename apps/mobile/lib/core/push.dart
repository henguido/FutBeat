import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_errors.dart';
import 'database.dart';
import 'live_realtime.dart';
import 'providers.dart';

String? reconcileSelectedCountry({
  required String? local,
  required String? cloud,
  required bool dirty,
}) => dirty ? local : cloud;

/// First link of this device with an account: the server row may be the
/// defaults its first read just created. Per field, a server value that
/// differs from its default is real evidence and wins, unless the guest
/// edited the profile on this device ([localEdited]); otherwise the local
/// value stays. A server default never replaces a local choice.
UserProfileSettings mergeFirstLinkProfile({
  required UserProfileSettings local,
  required UserProfileSettings cloud,
  required bool localEdited,
}) {
  final defaults = const UserProfileSettings().toJson();
  final localJson = local.toJson();
  final cloudJson = cloud.toJson();
  bool isDefault(String key, Object? value) =>
      value == null ||
      value == defaults[key] ||
      // The server's timezone default; the app's is 'device'.
      (key == 'timezone' && value == 'America/Costa_Rica');
  final merged = <String, dynamic>{};
  for (final key in {...localJson.keys, ...cloudJson.keys}) {
    final localValue = localJson[key];
    final cloudValue = cloudJson[key];
    final localChosen = !isDefault(key, localValue);
    final cloudChosen = !isDefault(key, cloudValue);
    merged[key] = localChosen && (localEdited || !cloudChosen)
        ? localValue
        : cloudChosen
        ? cloudValue
        : localValue;
  }
  return UserProfileSettings.fromJson(merged);
}

/// First link: a manual local country beats the server; otherwise the
/// server's explicit choice; never a server null over a local value.
String? mergeFirstLinkCountry({
  required String? local,
  required String? cloud,
  required bool localManual,
}) {
  if (localManual && local != null) return local;
  return cloud ?? local;
}

/// Diagnostic label for a failed account request: type, HTTP status and
/// the PostgREST/GoTrue error code only (never headers, tokens or bodies).
String describeAccountError(Object error) {
  if (error is! DioException) return '${error.runtimeType}';
  final data = error.response?.data;
  final code = data is Map ? (data['code'] ?? data['error_code']) : null;
  final message = data is Map ? '${data['message'] ?? ''}' : '';
  final short = message.length > 120 ? message.substring(0, 120) : message;
  return 'DioException ${error.type.name} '
          '${error.response?.statusCode ?? '-'} ${code ?? ''} $short'
      .trim();
}

/// Notification preference keys as the server stores them. The first seven
/// are understood by every server (`futbeat_sync_user_profile_v2`); the rest
/// only by servers with `futbeat_sync_user_profile_v3`.
const legacyNotificationKeys = [
  'notify_kickoff',
  'notify_goals',
  'notify_final',
  'notify_cards',
  'notify_lineups',
  'notify_news',
  'notify_transfers',
];

const extendedNotificationKeys = [
  'notify_red_cards',
  'notify_goal_annulled',
  'notify_player_starter',
  'notify_player_bench',
  'notify_player_sub_in',
  'notify_player_sub_out',
];

class UserProfileSettings {
  const UserProfileSettings({
    this.displayName,
    this.languageCode = 'es',
    this.timezone = 'device',
    this.hourFormat = 'system',
    this.notifyKickoff = true,
    this.notifyGoals = true,
    this.notifyFinal = true,
    this.notifyCards = true,
    this.notifyLineups = true,
    this.notifyNews = true,
    this.notifyTransfers = true,
    bool? notifyRedCards,
    bool? notifyGoalAnnulled,
    bool? notifyPlayerStarter,
    bool? notifyPlayerBench,
    this.notifyPlayerSubIn = true,
    this.notifyPlayerSubOut = true,
  }) : notifyRedCards = notifyRedCards ?? notifyCards,
       notifyGoalAnnulled = notifyGoalAnnulled ?? notifyGoals,
       notifyPlayerStarter = notifyPlayerStarter ?? notifyLineups,
       notifyPlayerBench = notifyPlayerBench ?? notifyLineups;

  final String? displayName;
  final String languageCode;
  final String timezone;
  final String hourFormat;
  final bool notifyKickoff;
  final bool notifyGoals;
  final bool notifyFinal;

  /// Legacy "Tarjetas" key. Old servers apply it to every card; it is kept
  /// equal to [notifyRedCards] so they only follow the red-card switch.
  final bool notifyCards;

  /// Legacy "Alineaciones" key: starter or bench alerts for old servers.
  final bool notifyLineups;
  final bool notifyNews;
  final bool notifyTransfers;
  final bool notifyRedCards;
  final bool notifyGoalAnnulled;
  final bool notifyPlayerStarter;
  final bool notifyPlayerBench;
  final bool notifyPlayerSubIn;
  final bool notifyPlayerSubOut;

  /// Reads camelCase (local storage, `futbeat_read_user_profile`) and
  /// snake_case server keys. A new key missing from an older payload
  /// inherits the legacy key it replaces.
  factory UserProfileSettings.fromJson(Map<String, dynamic> json) {
    Object? read(String camel, String snake) =>
        json.containsKey(camel) ? json[camel] : json[snake];
    bool? optional(String camel, String snake) {
      final value = read(camel, snake);
      return value is bool ? value : null;
    }

    final cards = _bool(read('notifyCards', 'notify_cards'), true);
    final goals = _bool(read('notifyGoals', 'notify_goals'), true);
    final lineups = _bool(read('notifyLineups', 'notify_lineups'), true);
    return UserProfileSettings(
      displayName: _cleanOptional(read('displayName', 'display_name')),
      languageCode: _clean(read('languageCode', 'language_code'), 'es'),
      timezone: _clean(json['timezone'], 'device'),
      hourFormat: _hourFormat(read('hourFormat', 'hour_format')),
      notifyKickoff: _bool(read('notifyKickoff', 'notify_kickoff'), true),
      notifyGoals: goals,
      notifyFinal: _bool(read('notifyFinal', 'notify_final'), true),
      notifyCards: cards,
      notifyLineups: lineups,
      notifyNews: _bool(read('notifyNews', 'notify_news'), true),
      notifyTransfers: _bool(read('notifyTransfers', 'notify_transfers'), true),
      notifyRedCards: optional('notifyRedCards', 'notify_red_cards') ?? cards,
      notifyGoalAnnulled:
          optional('notifyGoalAnnulled', 'notify_goal_annulled') ?? goals,
      notifyPlayerStarter:
          optional('notifyPlayerStarter', 'notify_player_starter') ?? lineups,
      notifyPlayerBench:
          optional('notifyPlayerBench', 'notify_player_bench') ?? lineups,
      notifyPlayerSubIn: _bool(
        read('notifyPlayerSubIn', 'notify_player_sub_in'),
        true,
      ),
      notifyPlayerSubOut: _bool(
        read('notifyPlayerSubOut', 'notify_player_sub_out'),
        true,
      ),
    );
  }

  static String _clean(dynamic value, String fallback) {
    final result = value?.toString().trim() ?? '';
    return result.isEmpty ? fallback : result;
  }

  static String? _cleanOptional(dynamic value) {
    final result = value?.toString().trim() ?? '';
    return result.isEmpty ? null : result;
  }

  static bool _bool(dynamic value, bool fallback) =>
      value is bool ? value : fallback;

  static String _hourFormat(dynamic value) {
    final format = value?.toString().trim() ?? '';
    return const {'system', '12h', '24h'}.contains(format) ? format : 'system';
  }

  Map<String, dynamic> toJson() => {
    'displayName': displayName,
    'languageCode': languageCode,
    'timezone': timezone,
    'hourFormat': hourFormat,
    'notifyKickoff': notifyKickoff,
    'notifyGoals': notifyGoals,
    'notifyFinal': notifyFinal,
    'notifyCards': notifyCards,
    'notifyLineups': notifyLineups,
    'notifyNews': notifyNews,
    'notifyTransfers': notifyTransfers,
    'notifyRedCards': notifyRedCards,
    'notifyGoalAnnulled': notifyGoalAnnulled,
    'notifyPlayerStarter': notifyPlayerStarter,
    'notifyPlayerBench': notifyPlayerBench,
    'notifyPlayerSubIn': notifyPlayerSubIn,
    'notifyPlayerSubOut': notifyPlayerSubOut,
  };

  /// Every notification preference under its server key (snake_case).
  Map<String, bool> get notificationPreferences => {
    'notify_kickoff': notifyKickoff,
    'notify_goals': notifyGoals,
    'notify_final': notifyFinal,
    'notify_cards': notifyCards,
    'notify_lineups': notifyLineups,
    'notify_news': notifyNews,
    'notify_transfers': notifyTransfers,
    'notify_red_cards': notifyRedCards,
    'notify_goal_annulled': notifyGoalAnnulled,
    'notify_player_starter': notifyPlayerStarter,
    'notify_player_bench': notifyPlayerBench,
    'notify_player_sub_in': notifyPlayerSubIn,
    'notify_player_sub_out': notifyPlayerSubOut,
  };

  /// Whether at least one alert type is on.
  bool get anyNotification => notificationPreferences.values.any((v) => v);

  UserProfileSettings copyWith({
    String? displayName,
    bool clearDisplayName = false,
    String? languageCode,
    String? timezone,
    String? hourFormat,
    bool? notifyKickoff,
    bool? notifyGoals,
    bool? notifyFinal,
    bool? notifyCards,
    bool? notifyLineups,
    bool? notifyNews,
    bool? notifyTransfers,
    bool? notifyRedCards,
    bool? notifyGoalAnnulled,
    bool? notifyPlayerStarter,
    bool? notifyPlayerBench,
    bool? notifyPlayerSubIn,
    bool? notifyPlayerSubOut,
  }) {
    final red = notifyRedCards ?? this.notifyRedCards;
    final starter = notifyPlayerStarter ?? this.notifyPlayerStarter;
    final bench = notifyPlayerBench ?? this.notifyPlayerBench;
    return UserProfileSettings(
      displayName: clearDisplayName ? null : (displayName ?? this.displayName),
      languageCode: languageCode ?? this.languageCode,
      timezone: timezone ?? this.timezone,
      hourFormat: hourFormat ?? this.hourFormat,
      notifyKickoff: notifyKickoff ?? this.notifyKickoff,
      notifyGoals: notifyGoals ?? this.notifyGoals,
      notifyFinal: notifyFinal ?? this.notifyFinal,
      // The red-card switch drives the legacy card key for old servers.
      notifyCards:
          notifyCards ?? (notifyRedCards != null ? red : this.notifyCards),
      // Starter/bench drive the legacy lineup key for old servers.
      notifyLineups:
          notifyLineups ??
          (notifyPlayerStarter != null || notifyPlayerBench != null
              ? starter || bench
              : this.notifyLineups),
      notifyNews: notifyNews ?? this.notifyNews,
      notifyTransfers: notifyTransfers ?? this.notifyTransfers,
      notifyRedCards: red,
      notifyGoalAnnulled: notifyGoalAnnulled ?? this.notifyGoalAnnulled,
      notifyPlayerStarter: starter,
      notifyPlayerBench: bench,
      notifyPlayerSubIn: notifyPlayerSubIn ?? this.notifyPlayerSubIn,
      notifyPlayerSubOut: notifyPlayerSubOut ?? this.notifyPlayerSubOut,
    );
  }
}

/// Initializes Firebase from the public build flags. Only call it when
/// [PushService.configured] is true.
Future<void> ensureFirebase() async {
  if (Firebase.apps.isNotEmpty) return;
  await Firebase.initializeApp(
    options: const FirebaseOptions(
      apiKey: String.fromEnvironment('FUTBEAT_FIREBASE_API_KEY'),
      appId: String.fromEnvironment('FUTBEAT_FIREBASE_APP_ID'),
      messagingSenderId: String.fromEnvironment('FUTBEAT_FIREBASE_SENDER_ID'),
      projectId: String.fromEnvironment('FUTBEAT_FIREBASE_PROJECT_ID'),
    ),
  );
}

abstract interface class PushTokenSource {
  Future<String?> requestToken();
  Stream<String> get rotations;
}

class FirebasePushTokens implements PushTokenSource {
  @override
  Future<String?> requestToken() async {
    await ensureFirebase();
    final permission = await FirebaseMessaging.instance.requestPermission();
    if (![
      AuthorizationStatus.authorized,
      AuthorizationStatus.provisional,
    ].contains(permission.authorizationStatus)) {
      return null;
    }
    if (Platform.isIOS &&
        await FirebaseMessaging.instance.getAPNSToken() == null) {
      return null;
    }
    return FirebaseMessaging.instance.getToken();
  }

  @override
  Stream<String> get rotations => FirebaseMessaging.instance.onTokenRefresh;
}

/// Social providers FutBeat signs in with through Supabase Auth.
enum OAuthProvider {
  google('google'),
  facebook('facebook');

  const OAuthProvider(this.id);
  final String id;
}

/// Opens [url] in a browser tab and completes with the redirect URL once it
/// reaches [callbackScheme]. Throws [OAuthCancelled] when the user closes it.
typedef OAuthBrowser = Future<String> Function(Uri url, String callbackScheme);

/// Sign-up for an address that already has an account. With email
/// confirmation on, GoTrue answers 200 with a user without identities and
/// sends no email (anti-enumeration): it must not read as "check your mail".
class AccountAlreadyExists implements Exception {
  const AccountAlreadyExists();
}

/// The user closed the provider page: not an error to show.
class OAuthCancelled implements Exception {
  const OAuthCancelled();
}

/// The provider or Supabase refused the sign-in (redirect error).
class OAuthFailed implements Exception {
  const OAuthFailed(this.code);
  final String code;
}

Future<String> _customTabBrowser(Uri url, String callbackScheme) async {
  try {
    return await FlutterWebAuth2.authenticate(
      url: url.toString(),
      callbackUrlScheme: callbackScheme,
    );
  } on PlatformException catch (error) {
    if (error.code == 'CANCELED') throw const OAuthCancelled();
    rethrow;
  }
}

class PushService {
  PushService(
    this.config,
    this.database,
    this.tokens, {
    Dio? dio,
    DateTime Function()? clock,
    this.signOutCleanupTimeout = const Duration(seconds: 5),
    bool? pushConfigured,
    OAuthBrowser? oauthBrowser,
    bool? oauthEnabled,
  }) : clock = clock ?? DateTime.now,
       oauthBrowser = oauthBrowser ?? _customTabBrowser,
       oauthEnabled = oauthEnabled ?? oauthConfigured,
       pushConfigured = pushConfigured ?? configured,
       dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 10),
               receiveTimeout: const Duration(seconds: 10),
             ),
           );

  final LiveRealtimeConfig config;
  final AppDatabase database;
  final PushTokenSource tokens;
  final Dio dio;
  final DateTime Function() clock;

  /// Upper bound for the background server sign-out; its requests are
  /// cancelled when it fires.
  final Duration signOutCleanupTimeout;

  /// [configured] unless a test overrides it.
  final bool pushConfigured;

  final OAuthBrowser oauthBrowser;

  /// [oauthConfigured] unless a test overrides it.
  final bool oauthEnabled;

  /// Social sign-in needs `com.futbeat.futbeat://login-callback` in the
  /// Supabase redirect allow list, which the app cannot check: builds opt
  /// in with FUTBEAT_OAUTH_ENABLED once it is configured.
  static const oauthConfigured = bool.fromEnvironment('FUTBEAT_OAUTH_ENABLED');
  static const oauthCallbackScheme = 'com.futbeat.futbeat';
  static const oauthRedirect = '$oauthCallbackScheme://login-callback';

  Set<OAuthProvider>? _oauthProviders;

  /// `futbeat_sync_user_profile_v3` answered "not found" on this
  /// server; later saves go straight to the legacy RPC.
  bool _preferencesRpcMissing = false;
  final storage = const FlutterSecureStorage();

  Map<String, dynamic>? _session;
  Map<String, dynamic>? get session => _session;

  /// Every session change goes through here, so [accountChanges] sees
  /// sign-in, restore, sign-out, deletion and dropped sessions alike.
  set session(Map<String, dynamic>? value) {
    final before = accountId;
    _session = value;
    final after = accountId;
    if (before != after && !_accountChanges.isClosed) {
      _accountChanges.add(after);
    }
  }

  final _accountChanges = StreamController<String?>.broadcast();
  final _profileChanges = StreamController<void>.broadcast();

  /// Fires whenever the local profile settings are written (edits, a
  /// reconcile with the account, sign-out resets).
  Stream<void> get profileChanges => _profileChanges.stream;

  /// Emits the signed-in account id (null = guest) whenever it changes.
  Stream<String?> get accountChanges => _accountChanges.stream;

  /// Signed-in account id, or null for a guest. Only meaningful once
  /// [accountKnown]: before that a stored session may still be loading.
  String? get accountId => authenticated ? userId : null;

  final _accountKnown = Completer<void>();

  /// True once startup knows whether a stored session exists (or a sign-in
  /// finished first). Until then "no account" does not mean guest.
  bool get accountKnown => _accountKnown.isCompleted;
  Future<void> get accountResolved => _accountKnown.future;

  void _markAccountKnown() {
    if (!_accountKnown.isCompleted) _accountKnown.complete();
  }

  String? pendingConfirmationEmail;
  String? token;
  StreamSubscription<String>? rotation;
  StreamSubscription<Set<String>>? follows;
  Timer? renewal;
  bool enabled = false;
  bool disposed = false;
  Future<void> pending = Future.value();
  Future<void> countryPending = Future.value();
  Future<void>? _restoreFuture;

  /// Bumped on every sign-in, sign-out and local session drop. Any network
  /// result that lands after the generation changed is discarded, so a late
  /// refresh can never resurrect a signed-out session.
  int _generation = 0;

  /// Generation in which the server follows were read and merged into
  /// Drift. Follows are never pushed (a full replace) before that.
  int _mergedGeneration = -1;
  Set<String>? _lastPushed;
  DateTime? _lastReconcile;
  Future<void>? _refreshing;
  int _refreshGeneration = -1;

  /// Best-effort server cleanup started by the last [signOut] (tests).
  Future<void> signOutCleanup = Future.value();

  /// Legacy key from 7ab628c; only deleted now.
  static const lastUserKey = 'futbeat.account.lastUser';

  /// Follows on the device when the last account signed out:
  /// `{"userId": ..., "follows": [...]}`. A different account signing in
  /// drops exactly these and keeps anything the guest added afterwards.
  static const leftoverKey = 'futbeat.account.leftover';
  static const _reconcileInterval = Duration(minutes: 5);
  static const _refreshMargin = Duration(minutes: 5);

  /// Legacy per-user flag from the first P1-C version; only deleted now.
  static String linkedFlagKey(String userId) =>
      'futbeat.account.linked.$userId';

  /// Last follow set successfully pushed for [userId] on this device: the
  /// base of the three-way merge.
  static String pushedKey(String userId) => 'futbeat.account.pushed.$userId';

  static const configured =
      bool.fromEnvironment('FUTBEAT_PUSH_ENABLED') &&
      String.fromEnvironment('FUTBEAT_FIREBASE_APP_ID') != '';

  bool get accountConfigured => config.isConfigured;
  bool get authenticated => session?['access_token'] != null;

  String? get userId {
    final user = session?['user'];
    if (user is! Map) return null;
    final value = user['id']?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  bool _stale(int generation) => disposed || generation != _generation;

  /// Only a map with non-empty access and refresh tokens is a session.
  static Map<String, dynamic>? _validSession(Object? data) {
    if (data is! Map) return null;
    final access = data['access_token'];
    final refresh = data['refresh_token'];
    if (access is! String || access.isEmpty) return null;
    if (refresh is! String || refresh.isEmpty) return null;
    return Map<String, dynamic>.from(data);
  }

  static DioException _invalidSession(RequestOptions options) =>
      DioException(requestOptions: options, message: 'Invalid session payload');

  bool _expiresSoon(DateTime now) {
    final raw = session?['expires_at'];
    final seconds = raw is num ? raw.toInt() : int.tryParse('$raw');
    if (seconds == null) return true;
    final expiry = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    return expiry.difference(now) < _refreshMargin;
  }

  String? get email {
    final user = session?['user'];
    if (user is Map) {
      final value = user['email']?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  bool? get emailVerified {
    final user = session?['user'];
    if (user is! Map) return null;
    final hasConfirmationClaim =
        user.containsKey('email_confirmed_at') ||
        user.containsKey('confirmed_at');
    if (!hasConfirmationClaim) return null;
    final value = user['email_confirmed_at'] ?? user['confirmed_at'];
    if (value == null) return false;
    return value.toString().trim().isNotEmpty;
  }

  Options get authHeaders => Options(
    headers: {
      'apikey': config.publicKey,
      'Authorization': 'Bearer ${session?['access_token']}',
    },
  );

  Future<void> signIn(String email, String password) async {
    if (!accountConfigured) {
      throw StateError('Account service is not configured');
    }
    await _awaitSignOutCleanup();
    final result = await dio.post<dynamic>(
      '${config.supabaseUrl}/auth/v1/token?grant_type=password',
      data: {'email': email.trim(), 'password': password},
      options: Options(headers: {'apikey': config.publicKey}),
    );
    final next = _validSession(result.data);
    if (next == null) throw _invalidSession(result.requestOptions);
    await _startSession(next);
  }

  /// Social providers enabled in Supabase Auth (public `/settings`), empty
  /// when social sign-in is off for this build or the answer is unknown.
  Future<Set<OAuthProvider>> oauthProviders() async {
    if (!accountConfigured || !oauthEnabled) return const {};
    final known = _oauthProviders;
    if (known != null) return known;
    try {
      final response = await dio.get<dynamic>(
        '${config.supabaseUrl}/auth/v1/settings',
        options: Options(headers: {'apikey': config.publicKey}),
      );
      final external = response.data is Map
          ? (response.data as Map)['external']
          : null;
      return _oauthProviders = {
        for (final provider in OAuthProvider.values)
          if (external is Map && external[provider.id] == true) provider,
      };
    } catch (_) {
      // Not cached: the next auth screen asks again.
      return const {};
    }
  }

  /// Google / Facebook through Supabase Auth with PKCE: the provider page
  /// opens in a browser tab, the redirect brings back a one-time code and
  /// only the code exchange creates the session. No provider secret lives
  /// in the app.
  Future<void> signInWithOAuth(OAuthProvider provider) async {
    if (!accountConfigured || !oauthEnabled) {
      throw StateError('Social sign-in is not configured');
    }
    await _awaitSignOutCleanup();
    final random = Random.secure();
    final verifier = base64Url
        .encode(List<int>.generate(48, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    final url = Uri.parse('${config.supabaseUrl}/auth/v1/authorize').replace(
      queryParameters: {
        'provider': provider.id,
        'redirect_to': oauthRedirect,
        'code_challenge': challenge,
        'code_challenge_method': 's256',
      },
    );
    final callback = Uri.parse(await oauthBrowser(url, oauthCallbackScheme));
    // GoTrue reports failures in the query or, for implicit errors, the
    // fragment.
    final params = {
      ...Uri.splitQueryString(callback.fragment),
      ...callback.queryParameters,
    };
    final error = params['error_code'] ?? params['error'];
    if (error != null) {
      if (error == 'access_denied') throw const OAuthCancelled();
      throw OAuthFailed(error);
    }
    final code = params['code'];
    if (code == null || code.isEmpty) throw const OAuthFailed('missing_code');
    final result = await dio.post<dynamic>(
      '${config.supabaseUrl}/auth/v1/token?grant_type=pkce',
      data: {'auth_code': code, 'code_verifier': verifier},
      options: Options(headers: {'apikey': config.publicKey}),
    );
    final next = _validSession(result.data);
    if (next == null) throw _invalidSession(result.requestOptions);
    await _startSession(next);
  }

  /// Provider of the current session ('email', 'google', 'facebook'), from
  /// the user's app metadata; null when unknown.
  String? get authProvider {
    final user = session?['user'];
    if (user is! Map) return null;
    final metadata = user['app_metadata'];
    if (metadata is! Map) return null;
    final value = metadata['provider']?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  /// Stores a fresh GoTrue session and starts account sync. A failed first
  /// reconcile (offline) is retried by the renewal tick; the session stays.
  Future<void> _startSession(Map<String, dynamic> value) async {
    _generation++;
    session = value;
    _markAccountKnown();
    _mergedGeneration = -1;
    _lastPushed = null;
    _lastReconcile = null;
    pendingConfirmationEmail = null;
    await storage.delete(key: 'futbeat.auth.pendingConfirmationEmail');
    await _persistSession();
    final generation = _generation;
    try {
      await _queued(() => _reconcileIfDue(generation));
    } catch (error) {
      // Retried by the renewal tick; the guest data stays local meanwhile.
      debugPrint('FutBeat account link pending (${error.runtimeType})');
    }
    if (_stale(generation)) return;
    await _startAccountSync();
  }

  /// A late sign-out request (device unregistration) must not land after
  /// the next sign-in or push enable. Bounded by [signOutCleanupTimeout].
  Future<void> _awaitSignOutCleanup() => signOutCleanup
      .timeout(signOutCleanupTimeout, onTimeout: () {})
      .catchError((_) {});

  /// Runs [work] on the account chain, after any tick/resume in flight.
  Future<void> _queued(Future<void> Function() work) {
    final operation = pending.catchError((_) {}).then((_) => work());
    pending = operation.catchError((_) {});
    return operation;
  }

  /// Reconciles unless this generation already reconciled recently (e.g.
  /// a resume that ran first at startup).
  Future<void> _reconcileIfDue(int generation) async {
    if (_stale(generation)) return;
    final last = _lastReconcile;
    if (_mergedGeneration == generation &&
        last != null &&
        clock().difference(last) < _reconcileInterval) {
      return;
    }
    await _reconcileAccount();
  }

  Future<void> signUp(String email, String password) async {
    if (!accountConfigured) {
      throw StateError('Account service is not configured');
    }
    final normalized = email.trim();
    await _awaitSignOutCleanup();
    final response = await dio.post<dynamic>(
      '${config.supabaseUrl}/auth/v1/signup',
      data: {'email': normalized, 'password': password},
      options: Options(headers: {'apikey': config.publicKey}),
    );
    final data = response.data;
    // With "Confirm email" disabled GoTrue returns a full session.
    final next = _validSession(data);
    if (next != null) {
      await _startSession(next);
      return;
    }
    if (data is Map && data['access_token'] != null) {
      throw _invalidSession(response.requestOptions);
    }
    final user = data is Map && data['user'] is Map ? data['user'] : data;
    if (user is Map &&
        user['identities'] is List &&
        (user['identities'] as List).isEmpty) {
      throw const AccountAlreadyExists();
    }
    pendingConfirmationEmail = normalized;
    await storage.write(
      key: 'futbeat.auth.pendingConfirmationEmail',
      value: normalized,
    );
  }

  /// Signed out, [emailAddress] (e.g. a sign-in refused with "confirm your
  /// email") takes precedence over the address of the last sign-up.
  Future<void> resendEmailConfirmation({String? emailAddress}) async {
    if (!accountConfigured) {
      throw StateError('Account service is not configured');
    }
    final typed = emailAddress?.trim();
    final currentEmail = authenticated
        ? email
        : (typed == null || typed.isEmpty ? pendingConfirmationEmail : typed);
    if (currentEmail == null || (authenticated && emailVerified != false)) {
      throw StateError('Email confirmation is not pending');
    }
    await dio.post(
      '${config.supabaseUrl}/auth/v1/resend',
      data: {'type': 'signup', 'email': currentEmail},
      options: Options(headers: {'apikey': config.publicKey}),
    );
  }

  /// "¿Olvidaste tu contraseña?": Supabase emails a one-time code. The
  /// project's "Reset password" email template must include {{ .Token }}.
  Future<void> requestPasswordReset(String emailAddress) async {
    if (!accountConfigured) {
      throw StateError('Account service is not configured');
    }
    await dio.post(
      '${config.supabaseUrl}/auth/v1/recover',
      data: {'email': emailAddress.trim()},
      options: Options(headers: {'apikey': config.publicKey}),
    );
  }

  /// Session from a verified recovery code whose password update has not
  /// succeeded yet. Never published: a retry reuses it instead of spending
  /// the one-time code again.
  Map<String, dynamic>? _recoverySession;
  String? _recoveryEmail;

  /// Verifies the emailed code, sets [newPassword] with that verified
  /// session and only then signs the account in (like [signIn]). A failed
  /// update leaves no session behind and can be retried.
  Future<void> resetPassword(
    String emailAddress,
    String code,
    String newPassword,
  ) async {
    if (!accountConfigured) {
      throw StateError('Account service is not configured');
    }
    await _awaitSignOutCleanup();
    final normalized = emailAddress.trim().toLowerCase();
    var verified = _recoveryEmail == normalized ? _recoverySession : null;
    if (verified == null) {
      final result = await dio.post<dynamic>(
        '${config.supabaseUrl}/auth/v1/verify',
        data: {
          'type': 'recovery',
          'email': emailAddress.trim(),
          'token': code.trim(),
        },
        options: Options(headers: {'apikey': config.publicKey}),
      );
      verified = _validSession(result.data);
      if (verified == null) throw _invalidSession(result.requestOptions);
      _recoverySession = verified;
      _recoveryEmail = normalized;
    }
    await dio.put<dynamic>(
      '${config.supabaseUrl}/auth/v1/user',
      data: {'password': newPassword},
      options: Options(
        headers: {
          'apikey': config.publicKey,
          'Authorization': 'Bearer ${verified['access_token']}',
        },
      ),
    );
    _recoverySession = null;
    _recoveryEmail = null;
    await _startSession(verified);
  }

  Future<void> restore() =>
      _restoreFuture ??= _restore().whenComplete(_markAccountKnown);

  Future<void> _restore() async {
    if (!accountConfigured || disposed) return;
    String? saved;
    try {
      pendingConfirmationEmail = await storage.read(
        key: 'futbeat.auth.pendingConfirmationEmail',
      );
      saved = await storage.read(key: 'futbeat.push.session');
    } catch (_) {
      return;
    }
    // A sign-in that finished while storage was read wins.
    if (saved == null || disposed || authenticated) return;
    final generation = _generation;
    try {
      final decoded = jsonDecode(saved);
      session = decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      session = null;
    }
    if (authenticated) _markAccountKnown();
    if (!authenticated) {
      await _clearLocalSession();
      return;
    }
    try {
      await refreshSession();
    } catch (error) {
      if (_stale(generation)) return;
      if (isAuthRejection(error)) {
        await _clearLocalSession();
        return;
      }
      // Offline/timeout/5xx/invalid body: keep the stored session; the
      // renewal tick or the next app resume retries the refresh.
    }
    if (_stale(generation) || !authenticated) return;
    try {
      await _queued(() => _reconcileIfDue(generation));
    } catch (_) {
      // Retried by the renewal tick/resume before any follows are pushed.
    }
    if (_stale(generation)) return;
    await _startAccountSync();
    try {
      if (pushConfigured &&
          await storage.read(key: 'futbeat.push.enabled') == 'true' &&
          !_stale(generation)) {
        await enable();
      }
    } catch (_) {
      enabled = false;
    }
  }

  /// Drops the local session, its merge base and account timers. Never
  /// touches Drift, so guest follows and preferences survive sign-out.
  Future<void> _clearLocalSession() async {
    final uid = userId;
    _generation++;
    renewal?.cancel();
    final oldFollows = follows;
    final oldRotation = rotation;
    follows = null;
    rotation = null;
    renewal = null;
    session = null;
    token = null;
    enabled = false;
    _mergedGeneration = -1;
    _lastPushed = null;
    _lastReconcile = null;
    await oldFollows?.cancel();
    await oldRotation?.cancel();
    await storage.delete(key: 'futbeat.push.session');
    if (uid != null) {
      // Remember what this account left on the device, so a different
      // account can drop exactly that. Without a merge in this session
      // (no P) an older snapshot is kept as is.
      if (await _readPushed(uid) != null) {
        final local = await database.watchFollows().first;
        await storage.write(
          key: leftoverKey,
          value: jsonEncode({'userId': uid, 'follows': local.toList()..sort()}),
        );
      }
      // The next sign-in of this user must union, never replace.
      await storage.delete(key: pushedKey(uid));
      await storage.delete(key: linkedFlagKey(uid));
    }
  }

  /// Retries refresh/reconcile after the app returns to the foreground.
  /// Refreshes only when the access token is close to expiry and runs the
  /// full reconcile at most every five minutes.
  Future<void> resume() {
    if (disposed || !authenticated) return Future.value();
    final operation = pending
        .catchError((_) {})
        .then((_) => _accountTick(throttled: true))
        .catchError((_) {});
    pending = operation;
    return operation;
  }

  Future<void> _persistSession() =>
      storage.write(key: 'futbeat.push.session', value: jsonEncode(session));

  /// Single-flight: concurrent callers share one request, so a rotating
  /// refresh token is never sent twice.
  Future<void> refreshSession() {
    if (!authenticated || disposed) return Future.value();
    final inFlight = _refreshing;
    if (inFlight != null && _refreshGeneration == _generation) return inFlight;
    final generation = _generation;
    _refreshGeneration = generation;
    final operation = _refresh(generation);
    _refreshing = operation;
    return operation.whenComplete(() {
      if (identical(_refreshing, operation)) _refreshing = null;
    });
  }

  Future<void> _refresh(int generation) async {
    final refreshToken = session?['refresh_token']?.toString();
    if (refreshToken == null || refreshToken.isEmpty) return;
    final result = await dio.post<dynamic>(
      '${config.supabaseUrl}/auth/v1/token?grant_type=refresh_token',
      data: {'refresh_token': refreshToken},
      options: Options(headers: {'apikey': config.publicKey}),
    );
    // Signed out (or another sign-in) while waiting: discard the result.
    if (_stale(generation)) return;
    final next = _validSession(result.data);
    if (next == null) throw _invalidSession(result.requestOptions);
    next['user'] ??= session?['user'];
    session = next;
    await _persistSession();
    if (_stale(generation) && !authenticated) {
      await storage.delete(key: 'futbeat.push.session');
    }
  }

  Future<String> installation() async {
    final old = await storage.read(key: 'futbeat.push.installation');
    if (old != null) return old;
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final id =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    await storage.write(key: 'futbeat.push.installation', value: id);
    return id;
  }

  Future<void> register(bool active) async {
    if (!authenticated || token == null || disposed) return;
    await dio.post(
      '${config.supabaseUrl}/rest/v1/rpc/futbeat_register_push',
      options: authHeaders,
      data: {
        'p_installation': await installation(),
        'p_platform': Platform.isIOS ? 'ios' : 'android',
        'p_transport': 'fcm',
        'p_token': token,
        'p_enabled': active,
      },
    );
  }

  /// Pushes [values] as a full replace of the server follows. Skipped until
  /// the server set has been read and merged into Drift in this session.
  Future<void> syncFollows(Set<String> values) =>
      _pushFollows(values, _generation);

  Future<void> _pushFollows(Set<String> values, int generation) async {
    if (!authenticated || _stale(generation)) return;
    if (_mergedGeneration != generation) return;
    final uid = userId;
    await dio.post(
      '${config.supabaseUrl}/rest/v1/rpc/futbeat_sync_push_follows',
      options: authHeaders,
      data: {
        'p_follows': values
            .where(
              (v) =>
                  v.startsWith('team:') ||
                  v.startsWith('player:') ||
                  v.startsWith('competition:') ||
                  v.startsWith('match:'),
            )
            .map(
              (v) => {
                'type': v.split(':').first,
                'id': v.substring(v.indexOf(':') + 1),
              },
            )
            .toList(),
      },
    );
    if (_stale(generation)) return;
    _lastPushed = Set.of(values);
    if (uid != null) {
      await storage.write(
        key: pushedKey(uid),
        value: jsonEncode(values.toList()..sort()),
      );
    }
  }

  static Set<String> _parseFollows(Object? json) {
    if (json is! List) throw const FormatException('Invalid follows payload');
    final result = <String>{};
    for (final item in json) {
      if (item is! Map) continue;
      final type = item['type']?.toString();
      final id = item['id']?.toString();
      if (type == null || id == null || type.isEmpty || id.isEmpty) continue;
      result.add('$type:$id');
    }
    return result;
  }

  Future<Set<String>?> _readPushed(String? uid) async {
    if (uid == null) return null;
    final raw = await storage.read(key: pushedKey(uid));
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.map((v) => '$v').toSet();
    } catch (_) {}
    return null;
  }

  Future<({String userId, Set<String> follows})?> _readLeftover() async {
    final raw = await storage.read(key: leftoverKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map &&
          decoded['userId'] is String &&
          decoded['follows'] is List) {
        return (
          userId: decoded['userId'] as String,
          follows: (decoded['follows'] as List).map((v) => '$v').toSet(),
        );
      }
    } catch (_) {}
    return null;
  }

  /// Three-way merge of server [serverJson] (S), local Drift (L) and the
  /// last pushed set (P), then a push of the result:
  /// - a different account left follows here (leftover O):
  ///   (L − O) ∪ S — its follows never leak, guest additions stay;
  /// - no P (first link, or after sign-out): L ∪ S;
  /// - otherwise L ∪ (S − P): keeps additions made elsewhere and local
  ///   removals.
  Future<void> _mergeFollows(Object? serverJson, int generation) async {
    final server = _parseFollows(serverJson);
    final uid = userId;
    final local = await database.watchFollows().first;
    final pushed = await _readPushed(uid);
    final leftover = await _readLeftover();
    if (_stale(generation)) return;

    final Set<String> next;
    if (uid != null && leftover != null && leftover.userId != uid) {
      next = {...local.difference(leftover.follows), ...server};
      final drop = local.difference(next);
      if (drop.isNotEmpty) await database.removeFollows(drop);
    } else {
      final incoming = pushed == null ? server : server.difference(pushed);
      next = {...local, ...incoming};
    }
    final missing = next.difference(local);
    if (missing.isNotEmpty) await database.addFollows(missing);
    if (_stale(generation)) return;
    if (leftover != null) await storage.delete(key: leftoverKey);
    await storage.delete(key: lastUserKey);
    _mergedGeneration = generation;
    await _pushFollows(next, generation);
  }

  /// Local follows changed: read S again and merge before pushing, so a
  /// push never drops follows added on another device.
  Future<void> _syncFollowsMerged(Set<String> values) async {
    final generation = _generation;
    if (!authenticated || _stale(generation)) return;
    if (_mergedGeneration != generation) return;
    final last = _lastPushed;
    if (last != null &&
        last.length == values.length &&
        last.containsAll(values)) {
      return;
    }
    final cloud = await _readCloudProfile();
    if (_stale(generation)) return;
    await _mergeFollows(cloud['follows'], generation);
  }

  Future<void> syncCountries(
    String? detected,
    String? selected, {
    bool updateDetected = true,
    bool updateSelected = true,
  }) {
    if (!authenticated || disposed) return Future.value();
    final sessionToken = session?['access_token']?.toString();
    final operation = countryPending.catchError((_) {}).then((_) async {
      if (updateDetected) await markDetectedCountryDirty();
      if (updateSelected) await markSelectedCountryDirty();
      if (disposed || session?['access_token']?.toString() != sessionToken) {
        return;
      }
      await dio.post(
        '${config.supabaseUrl}/rest/v1/rpc/futbeat_sync_user_preference_fields',
        options: authHeaders,
        data: {
          'p_detected': detected,
          'p_selected': selected,
          'p_update_detected': updateDetected,
          'p_update_selected': updateSelected,
        },
      );
      final current = await database.watchPreference().first;
      if (!disposed &&
          session?['access_token']?.toString() == sessionToken &&
          current.detectedCountry == detected &&
          current.selectedCountry == selected) {
        if (updateDetected) {
          await storage.write(
            key: 'futbeat.country.detected.dirty',
            value: 'false',
          );
        }
        if (updateSelected) {
          await storage.write(
            key: 'futbeat.country.selected.dirty',
            value: 'false',
          );
        }
        final detectedDirty =
            await storage.read(key: 'futbeat.country.detected.dirty') == 'true';
        final selectedDirty =
            await storage.read(key: 'futbeat.country.selected.dirty') == 'true';
        if (!detectedDirty && !selectedDirty) {
          await storage.write(key: 'futbeat.country.dirty', value: 'false');
        }
      }
    });
    countryPending = operation;
    return operation;
  }

  Future<void> markDetectedCountryDirty() async {
    await storage.write(key: 'futbeat.country.detected.dirty', value: 'true');
    await storage.write(key: 'futbeat.country.dirty', value: 'true');
  }

  Future<void> markSelectedCountryDirty() async {
    await storage.write(key: 'futbeat.country.selected.dirty', value: 'true');
    await storage.write(key: 'futbeat.country.dirty', value: 'true');
  }

  Future<void> touchInterest(String type, String id) async {
    if (!authenticated || disposed) return;
    try {
      await dio.post(
        '${config.supabaseUrl}/rest/v1/rpc/futbeat_touch_temporary_interest',
        options: authHeaders,
        data: {'p_type': type, 'p_id': id, 'p_ttl_minutes': 30},
      );
    } catch (_) {
      // Local temporary interest remains valid while offline or signed out.
    }
  }

  Future<UserProfileSettings> loadProfileSettings() async {
    try {
      final raw = await storage.read(key: 'futbeat.profile.settings');
      if (raw == null) return const UserProfileSettings();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const UserProfileSettings();
      return UserProfileSettings.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return const UserProfileSettings();
    }
  }

  Future<void> saveProfileSettings(UserProfileSettings settings) async {
    await _writeLocalProfile(settings, dirty: true);
    if (authenticated) {
      await _syncProfileSettings(settings);
    }
  }

  Future<void> _writeLocalProfile(
    UserProfileSettings settings, {
    required bool dirty,
  }) async {
    await storage.write(
      key: 'futbeat.profile.settings',
      value: jsonEncode(settings.toJson()),
    );
    await storage.write(
      key: 'futbeat.profile.dirty',
      value: dirty ? 'true' : 'false',
    );
    if (!_profileChanges.isClosed) _profileChanges.add(null);
  }

  /// A storage flag; an unreadable one counts as unset.
  Future<bool> _flag(String key) async {
    try {
      return await storage.read(key: key) == 'true';
    } catch (_) {
      return false;
    }
  }

  /// Saves the profile and every notification preference. Uses the JSON
  /// RPC `futbeat_sync_user_profile_v3` when the server has it and
  /// falls back to `futbeat_sync_user_profile_v2` (legacy keys only) when
  /// it does not.
  Future<void> _syncProfileSettings(UserProfileSettings settings) async {
    if (!authenticated || disposed) return;
    var saved = false;
    if (!_preferencesRpcMissing) {
      try {
        await dio.post(
          '${config.supabaseUrl}/rest/v1/rpc/futbeat_sync_user_profile_v3',
          options: authHeaders,
          data: {'p_profile': profilePayload(settings)},
        );
        saved = true;
      } on DioException catch (error) {
        if (!isMissingRpc(error)) rethrow;
        _preferencesRpcMissing = true;
      }
    }
    if (!saved) {
      await dio.post(
        '${config.supabaseUrl}/rest/v1/rpc/futbeat_sync_user_profile_v2',
        options: authHeaders,
        data: {
          'p_display_name': settings.displayName,
          'p_language_code': settings.languageCode,
          'p_timezone': settings.timezone,
          'p_hour_format': settings.hourFormat,
          for (final key in legacyNotificationKeys)
            'p_$key': settings.notificationPreferences[key],
        },
      );
    }
    await storage.write(key: 'futbeat.profile.dirty', value: 'false');
  }

  /// `p_profile` of `futbeat_sync_user_profile_v3`: every profile field
  /// and switch under its camelCase key (the server applies only the keys
  /// present; `notifyRedCards` also writes the legacy `notify_cards`).
  static Map<String, dynamic> profilePayload(UserProfileSettings settings) =>
      settings.toJson();

  /// PostgREST answers an unknown RPC with 404 / PGRST202.
  static bool isMissingRpc(DioException error) {
    final response = error.response;
    if (response == null) return false;
    final data = response.data;
    final code = data is Map ? data['code']?.toString() : null;
    return response.statusCode == 404 || code == 'PGRST202';
  }

  Future<Map<String, dynamic>> _readCloudProfile() async {
    final response = await dio.post<dynamic>(
      '${config.supabaseUrl}/rest/v1/rpc/futbeat_read_user_profile',
      options: authHeaders,
      data: const <String, dynamic>{},
    );
    final data = response.data;
    return data is Map ? Map<String, dynamic>.from(data) : {};
  }

  Future<void> _reconcileAccount() async {
    final generation = _generation;
    if (!authenticated || _stale(generation)) return;

    final cloud = await _readCloudProfile();
    if (_stale(generation)) return;
    // Never synced with this account on this device (first sign-in, or the
    // first after a sign-out): guest choices are linked, never replaced.
    final firstLink = await _readPushedSafe(userId) == null;
    final cloudPreferences = cloud['preferences'];

    // Every part runs even when another fails, favourites first: a profile
    // or country error never leaves them unsynced. The first error is
    // rethrown so the renewal tick retries the whole reconcile.
    Object? failure;
    StackTrace? failureStack;
    Future<void> step(String name, Future<void> Function() work) async {
      if (_stale(generation)) return;
      try {
        await work();
      } catch (error, stack) {
        debugPrint(
          'FutBeat account reconcile: $name failed (${describeAccountError(error)})',
        );
        failure ??= error;
        failureStack ??= stack;
      }
    }

    await step('follows', () => _mergeFollows(cloud['follows'], generation));
    await step(
      'profile',
      () => _reconcileProfile(cloudPreferences, firstLink: firstLink),
    );
    if (cloudPreferences is Map) {
      await step(
        'country',
        () => _reconcileCountries(
          Map<String, dynamic>.from(cloudPreferences),
          firstLink: firstLink,
        ),
      );
    }
    if (_stale(generation)) return;
    final error = failure;
    if (error != null) Error.throwWithStackTrace(error, failureStack!);
    _lastReconcile = clock();
  }

  Future<Set<String>?> _readPushedSafe(String? uid) async {
    try {
      return await _readPushed(uid);
    } catch (_) {
      return null;
    }
  }

  Future<void> _reconcileProfile(
    Object? cloudPreferences, {
    required bool firstLink,
  }) async {
    final dirty = await _flag('futbeat.profile.dirty');
    final localProfile = await loadProfileSettings();
    if (cloudPreferences is! Map) {
      await _syncProfileSettings(localProfile);
      return;
    }
    final cloudProfile = UserProfileSettings.fromJson(
      Map<String, dynamic>.from(cloudPreferences),
    );
    if (firstLink) {
      final merged = mergeFirstLinkProfile(
        local: localProfile,
        cloud: cloudProfile,
        localEdited: dirty,
      );
      if (jsonEncode(merged.toJson()) == jsonEncode(cloudProfile.toJson())) {
        // Nothing of the guest's to keep: the account's profile as is.
        await _writeLocalProfile(merged, dirty: false);
        return;
      }
      // Dirty until the server has the merged profile.
      await _writeLocalProfile(merged, dirty: true);
      await _syncProfileSettings(merged);
      return;
    }
    if (!dirty) {
      await _writeLocalProfile(cloudProfile, dirty: false);
    } else {
      await _syncProfileSettings(localProfile);
    }
  }

  Future<void> _reconcileCountries(
    Map<String, dynamic> values, {
    required bool firstLink,
  }) async {
    final current = await database.watchPreference().first;
    final legacyCountryDirty = await _flag('futbeat.country.dirty');
    var detectedDirty = await _flag('futbeat.country.detected.dirty');
    var selectedDirty = await _flag('futbeat.country.selected.dirty');
    if (legacyCountryDirty && !detectedDirty && !selectedDirty) {
      detectedDirty = true;
      selectedDirty = true;
    }
    final cloudDetected = values['detectedCountry']?.toString();
    final cloudSelected = values['selectedCountry']?.toString();
    final String? detected;
    final String? selected;
    if (firstLink) {
      // The device region is this device's fact; the choice follows the
      // first-link rule. Whatever differs is then written to the account.
      detected = current.detectedCountry ?? cloudDetected;
      selected = mergeFirstLinkCountry(
        local: current.selectedCountry,
        cloud: cloudSelected,
        localManual: selectedDirty,
      );
      detectedDirty = detected != cloudDetected;
      selectedDirty = selected != cloudSelected;
    } else {
      detected = reconcileSelectedCountry(
        local: current.detectedCountry,
        cloud: cloudDetected,
        dirty: detectedDirty,
      );
      selected = reconcileSelectedCountry(
        local: current.selectedCountry,
        cloud: cloudSelected,
        dirty: selectedDirty,
      );
    }
    if (detected != current.detectedCountry) {
      await database.saveDetectedCountry(detected);
    }
    if (selected != current.selectedCountry) {
      await database.saveSelectedCountry(selected);
    }
    if (detectedDirty || selectedDirty) {
      final effective = await database.watchPreference().first;
      await syncCountries(
        effective.detectedCountry,
        effective.selectedCountry,
        updateDetected: detectedDirty,
        updateSelected: selectedDirty,
      );
    }
  }

  Future<void> _startAccountSync() async {
    if (!authenticated || disposed) return;
    await follows?.cancel();
    renewal?.cancel();

    follows = database.watchFollows().listen((values) {
      pending = pending
          .catchError((_) {})
          .then((_) => _syncFollowsMerged(values))
          .catchError((_) {});
    });

    renewal = Timer.periodic(const Duration(minutes: 10), (_) {
      pending = pending
          .catchError((_) {})
          .then((_) => _accountTick())
          .catchError((_) {});
    });
  }

  Future<void> _accountTick({bool throttled = false}) async {
    final generation = _generation;
    if (!authenticated || _stale(generation)) return;
    final now = clock();
    final last = _lastReconcile;
    final needsRefresh = !throttled || _expiresSoon(now);
    final needsReconcile =
        !throttled ||
        _mergedGeneration != generation ||
        last == null ||
        now.difference(last) >= _reconcileInterval;
    if (needsRefresh) {
      try {
        await refreshSession();
      } catch (error) {
        if (_stale(generation)) return;
        if (isAuthRejection(error)) {
          await _clearLocalSession();
          return;
        }
        rethrow;
      }
    }
    if (_stale(generation)) return;
    // Reconcile reads the server first (3-way follows merge, dirty profile
    // and countries), so a tick never blindly replaces the server set.
    if (!throttled) {
      await _reconcileAccount();
    } else if (needsReconcile) {
      await _reconcileIfDue(generation);
    }
    if (_stale(generation)) return;
    if (!throttled && enabled) await register(true);
  }

  static const promptShownKey = 'futbeat.push.prompt.shownAt';
  static const promptInterval = Duration(days: 7);

  /// Whether to offer enabling notifications now: push is configured, the
  /// user is signed in, this device is not enabled yet and the prompt was
  /// not shown in the last [promptInterval].
  Future<bool> shouldPromptForNotifications() async {
    if (!pushConfigured || !authenticated || enabled || disposed) return false;
    try {
      if (await storage.read(key: 'futbeat.push.enabled') == 'true') {
        return false;
      }
      final raw = await storage.read(key: promptShownKey);
      final last = raw == null ? null : DateTime.tryParse(raw);
      return last == null || clock().difference(last) >= promptInterval;
    } catch (_) {
      return false;
    }
  }

  Future<void> markNotificationPromptShown() async {
    try {
      await storage.write(
        key: promptShownKey,
        value: clock().toUtc().toIso8601String(),
      );
    } catch (_) {}
  }

  Future<void> enable() async {
    await _awaitSignOutCleanup();
    if (!pushConfigured || !authenticated) {
      throw StateError('Push requires configuration and sign-in');
    }
    token = await tokens.requestToken();
    if (token == null) {
      throw StateError('Notification permission or device token unavailable');
    }
    await register(true);
    enabled = true;
    await storage.write(key: 'futbeat.push.enabled', value: 'true');

    await rotation?.cancel();
    rotation = tokens.rotations.listen((value) {
      pending = pending
          .catchError((_) {})
          .then((_) async {
            if (disposed || !enabled) return;
            token = value;
            await register(true);
          })
          .catchError((_) {});
    });

    await _startAccountSync();
  }

  Future<void> disable() async {
    await pending;
    await register(false);
    enabled = false;
    await rotation?.cancel();
    await storage.write(key: 'futbeat.push.enabled', value: 'false');
  }

  /// Always ends the local session immediately, even offline. Device
  /// unregistration and the server logout run in the background with a
  /// short timeout; Drift follows/preferences stay for the guest.
  Future<void> signOut() async {
    final headers = authenticated ? authHeaders : null;
    final deviceToken = enabled ? token : null;
    await _clearLocalSession();
    await storage.write(key: 'futbeat.push.enabled', value: 'false');
    if (headers == null) return;
    final cancel = CancelToken();
    final timer = Timer(signOutCleanupTimeout, () => cancel.cancel());
    signOutCleanup = _serverSignOut(
      headers,
      deviceToken,
      cancel,
    ).catchError((_) {}).whenComplete(timer.cancel);
  }

  /// Revokes only this session (scope=local), never the refresh tokens of
  /// a session started later on this or another device.
  Future<void> _serverSignOut(
    Options headers,
    String? deviceToken,
    CancelToken cancel,
  ) async {
    if (deviceToken != null) {
      try {
        await dio.post(
          '${config.supabaseUrl}/rest/v1/rpc/futbeat_register_push',
          options: headers,
          cancelToken: cancel,
          data: {
            'p_installation': await installation(),
            'p_platform': Platform.isIOS ? 'ios' : 'android',
            'p_transport': 'fcm',
            'p_token': deviceToken,
            'p_enabled': false,
          },
        );
      } catch (_) {
        // Offline: the device row may stay enabled server-side.
      }
    }
    if (cancel.isCancelled) return;
    await dio.post(
      '${config.supabaseUrl}/auth/v1/logout?scope=local',
      options: headers,
      cancelToken: cancel,
    );
  }

  Future<void> deleteAccount() async {
    if (!accountConfigured || !authenticated) {
      throw StateError('Authentication required');
    }
    final wasEnabled = enabled;
    await rotation?.cancel();
    await follows?.cancel();
    renewal?.cancel();
    rotation = null;
    follows = null;
    renewal = null;
    await pending.catchError((_) {});
    try {
      final response = await dio.post<Map<String, dynamic>>(
        '${config.supabaseUrl}/functions/v1/futbeat-delete-account',
        options: authHeaders,
      );
      if (response.data?['deleted'] != true) {
        throw StateError('Account deletion was not confirmed');
      }
    } catch (_) {
      if (authenticated && !disposed) {
        await _startAccountSync();
        if (wasEnabled) {
          enabled = true;
          rotation = tokens.rotations.listen((value) {
            pending = pending
                .catchError((_) {})
                .then((_) async {
                  if (disposed || !enabled) return;
                  token = value;
                  await register(true);
                })
                .catchError((_) {});
          });
        }
      }
      rethrow;
    }

    final deletedUser = userId;
    _generation++;
    enabled = false;
    token = null;
    session = null;
    _mergedGeneration = -1;
    _lastPushed = null;
    _lastReconcile = null;
    pending = Future.value();
    countryPending = Future.value();
    await storage.delete(key: 'futbeat.push.session');
    // Leftover follows are guest data now: the next sign-in unions them.
    await storage.delete(key: lastUserKey);
    await storage.delete(key: leftoverKey);
    if (deletedUser != null) {
      await storage.delete(key: pushedKey(deletedUser));
      await storage.delete(key: linkedFlagKey(deletedUser));
    }
    await storage.write(key: 'futbeat.push.enabled', value: 'false');
    await _writeLocalProfile(const UserProfileSettings(), dirty: false);
  }

  void dispose() {
    disposed = true;
    renewal?.cancel();
    unawaited(rotation?.cancel());
    unawaited(follows?.cancel());
    unawaited(_accountChanges.close());
    unawaited(_profileChanges.close());
    dio.close(force: true);
  }
}

final pushServiceProvider = Provider<PushService>((ref) {
  final service = PushService(
    ref.watch(liveRealtimeConfigProvider),
    ref.watch(databaseProvider),
    FirebasePushTokens(),
  );
  ref.onDispose(service.dispose);
  unawaited(service.restore());
  return service;
});

final profileSettingsProvider = FutureProvider<UserProfileSettings>((
  ref,
) async {
  final service = ref.watch(pushServiceProvider);
  final changes = service.profileChanges.listen((_) => ref.invalidateSelf());
  ref.onDispose(changes.cancel);
  await service.restore();
  return service.loadProfileSettings();
});

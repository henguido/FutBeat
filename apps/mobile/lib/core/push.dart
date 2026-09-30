import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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
  });

  final String? displayName;
  final String languageCode;
  final String timezone;
  final String hourFormat;
  final bool notifyKickoff;
  final bool notifyGoals;
  final bool notifyFinal;
  final bool notifyCards;
  final bool notifyLineups;
  final bool notifyNews;
  final bool notifyTransfers;

  factory UserProfileSettings.fromJson(Map<String, dynamic> json) =>
      UserProfileSettings(
        displayName: _cleanOptional(json['displayName']),
        languageCode: _clean(json['languageCode'], 'es'),
        timezone: _clean(json['timezone'], 'device'),
        hourFormat: _hourFormat(json['hourFormat']),
        notifyKickoff: _bool(json['notifyKickoff'], true),
        notifyGoals: _bool(json['notifyGoals'], true),
        notifyFinal: _bool(json['notifyFinal'], true),
        notifyCards: _bool(json['notifyCards'], true),
        notifyLineups: _bool(json['notifyLineups'], true),
        notifyNews: _bool(json['notifyNews'], true),
        notifyTransfers: _bool(json['notifyTransfers'], true),
      );

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
  };

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
  }) => UserProfileSettings(
    displayName: clearDisplayName ? null : (displayName ?? this.displayName),
    languageCode: languageCode ?? this.languageCode,
    timezone: timezone ?? this.timezone,
    hourFormat: hourFormat ?? this.hourFormat,
    notifyKickoff: notifyKickoff ?? this.notifyKickoff,
    notifyGoals: notifyGoals ?? this.notifyGoals,
    notifyFinal: notifyFinal ?? this.notifyFinal,
    notifyCards: notifyCards ?? this.notifyCards,
    notifyLineups: notifyLineups ?? this.notifyLineups,
    notifyNews: notifyNews ?? this.notifyNews,
    notifyTransfers: notifyTransfers ?? this.notifyTransfers,
  );
}

abstract interface class PushTokenSource {
  Future<String?> requestToken();
  Stream<String> get rotations;
}

class FirebasePushTokens implements PushTokenSource {
  @override
  Future<String?> requestToken() async {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: String.fromEnvironment('FUTBEAT_FIREBASE_API_KEY'),
          appId: String.fromEnvironment('FUTBEAT_FIREBASE_APP_ID'),
          messagingSenderId: String.fromEnvironment(
            'FUTBEAT_FIREBASE_SENDER_ID',
          ),
          projectId: String.fromEnvironment('FUTBEAT_FIREBASE_PROJECT_ID'),
        ),
      );
    }
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

class PushService {
  PushService(
    this.config,
    this.database,
    this.tokens, {
    Dio? dio,
    DateTime Function()? clock,
    this.signOutCleanupTimeout = const Duration(seconds: 5),
  }) : clock = clock ?? DateTime.now,
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
  final storage = const FlutterSecureStorage();

  Map<String, dynamic>? session;
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

  /// Stores a fresh GoTrue session and starts account sync. A failed first
  /// reconcile (offline) is retried by the renewal tick; the session stays.
  Future<void> _startSession(Map<String, dynamic> value) async {
    _generation++;
    session = value;
    _mergedGeneration = -1;
    _lastPushed = null;
    _lastReconcile = null;
    pendingConfirmationEmail = null;
    await storage.delete(key: 'futbeat.auth.pendingConfirmationEmail');
    await _persistSession();
    final generation = _generation;
    try {
      await _queued(() => _reconcileIfDue(generation));
    } catch (_) {
      // Follows stay unpushed until a later reconcile merges the server set.
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
    pendingConfirmationEmail = normalized;
    await storage.write(
      key: 'futbeat.auth.pendingConfirmationEmail',
      value: normalized,
    );
  }

  Future<void> resendEmailConfirmation() async {
    if (!accountConfigured) {
      throw StateError('Account service is not configured');
    }
    final currentEmail = authenticated ? email : pendingConfirmationEmail;
    if (currentEmail == null || (authenticated && emailVerified != false)) {
      throw StateError('Email confirmation is not pending');
    }
    await dio.post(
      '${config.supabaseUrl}/auth/v1/resend',
      data: {'type': 'signup', 'email': currentEmail},
      options: Options(headers: {'apikey': config.publicKey}),
    );
  }

  Future<void> restore() => _restoreFuture ??= _restore();

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
      if (configured &&
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
  }

  Future<void> _syncProfileSettings(UserProfileSettings settings) async {
    if (!authenticated || disposed) return;
    await dio.post(
      '${config.supabaseUrl}/rest/v1/rpc/futbeat_sync_user_profile_v2',
      options: authHeaders,
      data: {
        'p_display_name': settings.displayName,
        'p_language_code': settings.languageCode,
        'p_timezone': settings.timezone,
        'p_hour_format': settings.hourFormat,
        'p_notify_kickoff': settings.notifyKickoff,
        'p_notify_goals': settings.notifyGoals,
        'p_notify_final': settings.notifyFinal,
        'p_notify_cards': settings.notifyCards,
        'p_notify_lineups': settings.notifyLineups,
        'p_notify_news': settings.notifyNews,
        'p_notify_transfers': settings.notifyTransfers,
      },
    );
    await storage.write(key: 'futbeat.profile.dirty', value: 'false');
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
    final cloudPreferences = cloud['preferences'];
    final dirty = await storage.read(key: 'futbeat.profile.dirty') == 'true';
    final localProfile = await loadProfileSettings();

    if (!dirty && cloudPreferences is Map) {
      await _writeLocalProfile(
        UserProfileSettings.fromJson(
          Map<String, dynamic>.from(cloudPreferences),
        ),
        dirty: false,
      );
    } else {
      await _syncProfileSettings(localProfile);
    }

    if (cloudPreferences is Map) {
      final values = Map<String, dynamic>.from(cloudPreferences);
      final current = await database.watchPreference().first;
      final legacyCountryDirty =
          await storage.read(key: 'futbeat.country.dirty') == 'true';
      var detectedDirty =
          await storage.read(key: 'futbeat.country.detected.dirty') == 'true';
      var selectedDirty =
          await storage.read(key: 'futbeat.country.selected.dirty') == 'true';
      if (legacyCountryDirty && !detectedDirty && !selectedDirty) {
        detectedDirty = true;
        selectedDirty = true;
      }
      final cloudDetected = values['detectedCountry']?.toString();
      final cloudSelected = values['selectedCountry']?.toString();
      final detected = reconcileSelectedCountry(
        local: current.detectedCountry,
        cloud: cloudDetected,
        dirty: detectedDirty,
      );
      final selected = reconcileSelectedCountry(
        local: current.selectedCountry,
        cloud: cloudSelected,
        dirty: selectedDirty,
      );
      if (detected != current.detectedCountry ||
          selected != current.selectedCountry) {
        if (detected != current.detectedCountry) {
          await database.saveDetectedCountry(detected);
        }
        if (selected != current.selectedCountry) {
          await database.saveSelectedCountry(selected);
        }
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

    if (_stale(generation)) return;
    await _mergeFollows(cloud['follows'], generation);
    if (!_stale(generation)) _lastReconcile = clock();
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

  Future<void> enable() async {
    await _awaitSignOutCleanup();
    if (!configured || !authenticated) {
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
  await service.restore();
  return service.loadProfileSettings();
});

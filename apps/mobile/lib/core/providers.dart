import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database.dart';
import 'entity_media.dart';
import 'interests.dart';
import 'live_realtime.dart';
import 'models.dart';
import 'player_display_identity.dart';
import 'profile_context.dart';
import 'team_matches.dart';

abstract interface class FootballRepository {
  Future<Snapshot> load();
  Future<Snapshot> loadDate(DateTime date);
  Future<MatchDetail> loadMatchDetail(String id);
}

class DemoRepository implements FootballRepository {
  @override
  Future<Snapshot> load() async => Snapshot(
    jsonDecode(await rootBundle.loadString('assets/demo.snapshot.json'))
        as Json,
  );

  @override
  Future<Snapshot> loadDate(DateTime date) => load();

  @override
  Future<MatchDetail> loadMatchDetail(String id) async => MatchDetail.empty(id);
}

/// Client calendar cache policy, in one place. Generic: rules depend only on
/// the distance of a date to today, never on leagues, teams or fixed dates.
class CalendarCachePolicy {
  const CalendarCachePolicy({
    this.todayTtl = const Duration(seconds: 20),
    this.pastTtl = const Duration(minutes: 5),
    this.futureTtl = const Duration(minutes: 10),
    this.recoveringTtl = const Duration(seconds: 20),
    this.prefetchRadius = 2,
    this.windowBackDays = 2,
    this.windowForwardDays = 7,
    this.receiveTimeout = const Duration(seconds: 10),
    this.visibleDeadline = const Duration(seconds: 25),
    this.maxAttempts = 3,
    this.pendingPollMin = const Duration(seconds: 2),
    this.pendingPollMax = const Duration(seconds: 8),
    this.revalidateEvery = const Duration(seconds: 30),
    this.revalidateMax = const Duration(minutes: 5),
  });

  final Duration todayTtl;
  final Duration pastTtl;
  final Duration futureTtl;

  /// Partial or stale snapshots are revalidated sooner.
  final Duration recoveringTtl;

  /// Neighbours prepared around the visible date: D+1, D-1, D+2, D-2, ...
  final int prefetchRadius;

  /// Prefetch only inside this window around today (no history cascade).
  final int windowBackDays;
  final int windowForwardDays;
  final Duration receiveTimeout;

  /// Total time a visible date may wait (requests, retries and "pending"
  /// polls). After it, the date ends in data or in an error with Retry; it is
  /// never an endless loading state.
  final Duration visibleDeadline;
  final int maxAttempts;

  /// The server may answer "pending" while it materializes a large day; the
  /// client polls on the server hint, clamped to this range.
  final Duration pendingPollMin;
  final Duration pendingPollMax;

  /// Background revalidation of a visible date that has data; doubled per
  /// consecutive failure up to [revalidateMax]. A date that never obtained a
  /// snapshot is not revalidated on a timer (the user retries).
  final Duration revalidateEvery;
  final Duration revalidateMax;

  Duration revalidateAfter(int failures) {
    final factor = 1 << (failures.clamp(0, 10));
    final delay = revalidateEvery * factor;
    return delay > revalidateMax ? revalidateMax : delay;
  }

  Duration ttl(String date, String today, {required bool recovering}) =>
      recovering
      ? recoveringTtl
      : date == today
      ? todayTtl
      : date.compareTo(today) < 0
      ? pastTtl
      : futureTtl;
}

/// One shared network request per date. Callers that pass a cancel token only
/// stop waiting; the request itself is cancelled when no waiter remains, so a
/// closed screen never cancels a prefetch (or another screen) of the same date.
class _CalendarFlight {
  final CancelToken token = CancelToken();
  late final Future<Snapshot> future;
  int _waiters = 0;
  bool _pinned = false;

  void pin() => _pinned = true;
  void join() => _waiters++;
  void leave() {
    if (--_waiters <= 0 && !_pinned && !token.isCancelled) {
      token.cancel('No calendar waiters');
    }
  }
}

/// A catalog answer (Explorar, search) younger than this is served from
/// memory without a request.
const catalogMemoryTtl = Duration(minutes: 1);

class ApiRepository implements FootballRepository {
  ApiRepository(
    this.dio, [
    this.database,
    this.calendarPolicy = const CalendarCachePolicy(),
    this.media,
  ]);
  final Dio dio;
  final AppDatabase? database;
  final CalendarCachePolicy calendarPolicy;

  /// Receives every snapshot read, so lazily hydrated media reaches every
  /// screen showing the same entity.
  final EntityMediaMemory? media;

  final Map<String, DateTime> _calendarFetchedAt = {};
  final Map<String, int> _calendarFailures = {};
  final Map<String, _CalendarFlight> _calendarInFlight = {};
  final Set<Future<void>> _diskWrites = {};
  Future<void> _prefetchTask = Future<void>.value();
  int _prefetchGeneration = 0;
  final Set<String> _forcedDates = {};
  final Map<String, DateTime> _catalogFetchedAt = {};
  final Set<String> _detailRequested = {};
  final Map<String, Future<MatchDetail>> _detailRequestInFlight = {};

  final Map<String, Snapshot> _snapshotCache = <String, Snapshot>{};

  static String _dateParam(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  Snapshot _canonical(Json json) {
    final snapshot = Snapshot(
      json,
      blockedAliasIds: media?.revokedDisplayAliases ?? const {},
    );
    if (snapshot.demo) {
      throw StateError('Cloud endpoint returned demo data');
    }
    final before = media?.revokedDisplayAliases ?? const <String>{};
    media?.absorb(snapshot);
    final after = media?.revokedDisplayAliases ?? const <String>{};
    if (before.length != after.length) {
      _snapshotCache.updateAll((_, cached) => cached.withBlockedAliases(after));
      return snapshot.withBlockedAliases(after);
    }
    return snapshot;
  }

  bool _retryable(Object error) {
    if (error is! DioException) return false;
    final status = error.response?.statusCode;
    if (status == 502 || status == 503 || status == 504) return true;
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError ||
      DioExceptionType.unknown => true,
      _ => false,
    };
  }

  Future<Json> _getJson(
    String path, {
    Map<String, dynamic>? queryParameters,
    int maxAttempts = 2,
    CancelToken? cancelToken,
    Duration? receiveTimeout,
  }) async {
    Object? lastError;
    StackTrace? lastStack;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final response = await dio.get<Json>(
          path,
          queryParameters: queryParameters,
          cancelToken: cancelToken,
          options: Options(
            receiveTimeout:
                receiveTimeout ??
                (path == '/v1/match-detail'
                    ? const Duration(seconds: 3)
                    : null),
            headers: {if (attempt > 0) 'X-Retry-Count': '1'},
          ),
        );
        final data = response.data;
        if (data == null) {
          throw const FormatException('Cloud endpoint returned no data');
        }
        return data;
      } catch (error, stack) {
        lastError = error;
        lastStack = stack;
        if (attempt + 1 < maxAttempts && _retryable(error)) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          continue;
        }
        break;
      }
    }

    Error.throwWithStackTrace(lastError!, lastStack!);
  }

  void _remember(String key, Snapshot snapshot) {
    _snapshotCache.remove(key);
    _snapshotCache[key] = snapshot;
    while (_snapshotCache.length > 64) {
      final oldest = _snapshotCache.keys.first;
      _snapshotCache.remove(oldest);
      if (oldest.startsWith('calendar:')) {
        _calendarFetchedAt.remove(oldest.substring('calendar:'.length));
      }
    }
  }

  Future<Snapshot> _loadSnapshot(
    String key,
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    try {
      final snapshot = _canonical(
        await _getJson(path, queryParameters: queryParameters),
      );
      _remember(key, snapshot);
      return snapshot;
    } catch (error, stack) {
      final cached = _snapshotCache[key];
      if (cached != null) return cached.asStale();
      Error.throwWithStackTrace(error, stack);
    }
  }

  @override
  Future<Snapshot> load() => _loadSnapshot('snapshot', '/v1/snapshot');

  bool _freshDate(String value) {
    if (_forcedDates.contains(value)) return false;
    final fetched = _calendarFetchedAt[value];
    if (fetched == null) return false;
    final snapshot = _snapshotCache['calendar:$value'];
    // Partial, stale or still-live days (e.g. yesterday just after midnight)
    // revalidate on the short TTL.
    final recovering =
        snapshot?.coverage?['partial'] == true ||
        snapshot?.stale == true ||
        snapshot?.revalidating == true ||
        (snapshot?.matches.any((match) => match.isLive) ?? false);
    final ttl = calendarPolicy.ttl(
      value,
      _dateParam(costaRicaNow()),
      recovering: recovering,
    );
    return DateTime.now().toUtc().difference(fetched) < ttl;
  }

  /// Memory-only, synchronous lookup: a date switch paints the cached day in
  /// the same frame instead of flashing a loading state.
  Snapshot? peekDate(DateTime date) =>
      _snapshotCache['calendar:${_dateParam(date)}'];

  /// Waits for background prefetch and disk writes (tests and shutdown).
  Future<void> settleBackground() async {
    await _prefetchTask;
    await Future.wait([..._diskWrites]);
  }

  Future<Snapshot?> _readStored(String value) async {
    final key = 'calendar:$value';
    final memory = _snapshotCache[key];
    if (memory != null) return memory;
    try {
      final stored = await database?.readCalendarEntry(value);
      if (stored == null) return null;
      final snapshot = _canonical(jsonDecode(stored.payload) as Json);
      _remember(key, snapshot);
      _calendarFetchedAt[value] = stored.savedAt.toUtc();
      return snapshot;
    } catch (_) {
      // An unreadable/corrupt local row is replaced by the next response.
      return null;
    }
  }

  void _persist(String value, Json raw) {
    final db = database;
    if (db == null) return;
    // Never delays showing fresh data: memory already holds the snapshot.
    late final Future<void> write;
    write = db
        .saveCalendarSnapshot(value, jsonEncode(raw))
        .catchError((Object _) {})
        .whenComplete(() => _diskWrites.remove(write));
    _diskWrites.add(write);
  }

  _CalendarFlight _startFlight(String value) {
    final flight = _CalendarFlight();
    flight.future = () async {
      try {
        final raw = await _getJson(
          '/v1/calendar',
          queryParameters: {'date': value, 'timezone': 'America/Costa_Rica'},
          cancelToken: flight.token,
          maxAttempts: 1,
          receiveTimeout: calendarPolicy.receiveTimeout,
        );
        final fresh = _canonical(raw);
        // A "pending" answer (server still materializing) is never cached.
        if (fresh.calendarPending) return fresh;
        _remember('calendar:$value', fresh);
        _calendarFetchedAt[value] = DateTime.now().toUtc();
        _forcedDates.remove(value);
        _persist(value, raw);
        return fresh;
      } finally {
        if (identical(_calendarInFlight[value], flight)) {
          _calendarInFlight.remove(value);
        }
      }
    }();
    // Errors reach the waiters; an abandoned flight is never unhandled.
    unawaited(flight.future.then((_) {}, onError: (Object _) {}));
    return flight;
  }

  Future<Snapshot> _fetchDate(String value, {CancelToken? cancelToken}) {
    if (cancelToken != null && cancelToken.isCancelled) {
      return Future.error(cancelToken.cancelError!);
    }
    var flight = _calendarInFlight[value];
    if (flight == null || flight.token.isCancelled) {
      flight = _calendarInFlight[value] = _startFlight(value);
    }
    if (cancelToken == null) {
      flight.pin();
      return flight.future;
    }
    final current = flight..join();
    var joined = true;
    void leave() {
      if (!joined) return;
      joined = false;
      current.leave();
    }

    final result = Completer<Snapshot>();
    current.future.then(
      (snapshot) {
        leave();
        if (!result.isCompleted) result.complete(snapshot);
      },
      onError: (Object error, StackTrace stack) {
        leave();
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    cancelToken.whenCancel.then((error) {
      leave();
      if (!result.isCompleted) result.completeError(error);
    });
    return result.future;
  }

  @override
  Future<Snapshot> loadDate(DateTime date) => _fetchDate(_dateParam(date));

  /// Delay before revalidating a visible date that has data (backoff after
  /// consecutive failures).
  Duration calendarRevalidateDelay(DateTime date) =>
      calendarPolicy.revalidateAfter(_calendarFailures[_dateParam(date)] ?? 0);

  /// Cache first, then the network, within [CalendarCachePolicy.visibleDeadline].
  /// Terminal states: a snapshot (fresh, or the cached one marked stale) or
  /// an error when nothing was ever available. Never an endless loop.
  Stream<Snapshot> watchDate(
    DateTime date, {
    CancelToken? cancelToken,
    Duration retryDelay = const Duration(seconds: 1),
  }) async* {
    final value = _dateParam(date);
    final deadline = DateTime.now().add(calendarPolicy.visibleDeadline);
    Snapshot? cached = await _readStored(value);
    final freshCache = cached != null && _freshDate(value);
    if (cached != null) yield cached.withFreshness(revalidating: !freshCache);
    if (freshCache) {
      _prefetchAround(date);
      return;
    }
    Future<bool> wait(Duration delay) async {
      if (DateTime.now().add(delay).isAfter(deadline)) return false;
      await Future.any([
        Future<void>.delayed(delay),
        if (cancelToken != null) cancelToken.whenCancel,
      ]);
      return cancelToken?.isCancelled != true;
    }

    var failures = 0;
    var polls = 0;
    Object? lastError;
    StackTrace? lastStack;
    while (true) {
      if (cancelToken?.isCancelled == true) return;
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        lastError ??= TimeoutException(
          'Calendar date not loaded in time',
          calendarPolicy.visibleDeadline,
        );
        lastStack ??= StackTrace.current;
        break;
      }
      try {
        // The visible wait never outlives the deadline; the shared request
        // itself continues for other waiters and fills the cache.
        final snapshot = await _fetchDate(
          value,
          cancelToken: cancelToken,
        ).timeout(remaining);
        if (snapshot.calendarPending) {
          // The server is materializing this day: show the preparing state
          // (only without data) and poll on its hint, within the deadline.
          if (cached == null) yield snapshot;
          final hint = Duration(seconds: snapshot.calendarRetryAfterSeconds);
          var delay = hint * (1 << polls.clamp(0, 3));
          if (delay < calendarPolicy.pendingPollMin) {
            delay = calendarPolicy.pendingPollMin;
          }
          if (delay > calendarPolicy.pendingPollMax) {
            delay = calendarPolicy.pendingPollMax;
          }
          polls++;
          if (await wait(delay)) continue;
          if (cancelToken?.isCancelled == true) return;
          lastError = TimeoutException(
            'Calendar date is still being prepared',
            calendarPolicy.visibleDeadline,
          );
          lastStack = StackTrace.current;
          break;
        }
        _calendarFailures.remove(value);
        yield snapshot;
        _prefetchAround(date);
        return;
      } catch (error, stack) {
        if (cancelToken?.isCancelled == true) return;
        lastError = error;
        lastStack = stack;
        failures++;
        if (cached != null) yield cached.asStale();
        if (failures >= calendarPolicy.maxAttempts) break;
        if (!await wait(retryDelay * failures)) {
          if (cancelToken?.isCancelled == true) return;
          break;
        }
      }
    }
    _calendarFailures[value] = (_calendarFailures[value] ?? 0) + 1;
    if (cached != null) {
      // Keep showing the data (already marked stale after a failure);
      // background revalidation backs off.
      if (failures == 0) yield cached.asStale();
      return;
    }
    Error.throwWithStackTrace(lastError, lastStack);
  }

  /// Prepares the neighbours of the visible date one at a time (D+1, D-1,
  /// D+2, D-2, ...), only inside the window around today. A newer visible date
  /// supersedes the previous chain; missing and expired days are both fetched.
  void _prefetchAround(DateTime anchor) {
    final generation = ++_prefetchGeneration;
    final now = costaRicaNow();
    final today = DateTime.utc(now.year, now.month, now.day);
    final previous = _prefetchTask;
    _prefetchTask = () async {
      // Chains run one after another (never parallel bursts).
      await previous;
      for (var step = 1; step <= calendarPolicy.prefetchRadius; step++) {
        for (final sign in const [1, -1]) {
          if (generation != _prefetchGeneration) return;
          final day = DateTime.utc(
            anchor.year,
            anchor.month,
            anchor.day + sign * step,
          );
          final offset = day.difference(today).inDays;
          if (offset < -calendarPolicy.windowBackDays ||
              offset > calendarPolicy.windowForwardDays) {
            continue;
          }
          await prefetchDate(DateTime(day.year, day.month, day.day));
        }
      }
    }();
  }

  Future<void> prefetchDate(DateTime date) async {
    final value = _dateParam(date);
    try {
      await _readStored(value);
      if (_freshDate(value)) return;
      await _fetchDate(value);
    } catch (_) {
      // Opportunistic, deduplicated and independent of the visible request.
    }
  }

  void refreshDate(DateTime date) {
    _forcedDates.add(_dateParam(date));
    _calendarFetchedAt.remove(_dateParam(date));
  }

  /// What this session already read about a team (search, Explorar,
  /// calendar days, favorites…), as a minimal snapshot: the team itself and
  /// its main competition when known. A profile paints its header from it at
  /// once while `/v1/entity` loads. Memory only: never a request. Null when
  /// nothing read so far mentions the team.
  Snapshot? entitySeed(String type, String id) {
    if (type != 'team') return null;
    final snapshots = _snapshotCache.values.toList().reversed.toList();
    for (final snapshot in snapshots) {
      final resolved = snapshot.resolveEntityId(id);
      final team = snapshot.team(resolved);
      if (team == null) continue;
      final competitionId = team.json['competitionId']?.toString() ?? '';
      Entity? competition;
      if (competitionId.isNotEmpty) {
        for (final other in [snapshot, ...snapshots]) {
          competition = other.competition(competitionId);
          if (competition != null) break;
        }
      }
      return Snapshot({
        'schemaVersion': 1,
        'demo': false,
        'coverage': {'seed': true},
        'updatedAt': snapshot.updatedAt.toIso8601String(),
        'entityRedirects': {if (resolved != id) id: resolved},
        'teams': [team.json],
        'players': const <dynamic>[],
        'competitions': [?competition?.json],
        'matches': const <dynamic>[],
        'standings': const <dynamic>[],
        'news': const <dynamic>[],
        'transfers': const <dynamic>[],
      });
    }
    return null;
  }

  Future<Snapshot> loadEntity(String type, String id) async {
    final decision = type == 'player' ? adjudicationForAlias(id) : null;
    if (decision == null || media?.revokedDisplayAliases.contains(id) == true) {
      return _loadSnapshot(
        'entity:$type:$id',
        '/v1/entity',
        queryParameters: {'type': type, 'id': id},
      );
    }
    final key = 'entity:$type:$id';
    Json raw;
    try {
      raw = await _getJson(
        '/v1/entity',
        queryParameters: {'type': type, 'id': id},
      );
    } catch (error, stack) {
      final cached = _snapshotCache[key];
      if (cached != null) return cached.asStale();
      Error.throwWithStackTrace(error, stack);
    }
    if (raw['schemaVersion'] != 1 || raw['demo'] != false) {
      throw const FormatException('Versión de datos incompatible');
    }
    if ((raw['entityRedirects'] as Map?)?.containsKey(id) == true) {
      final canonical = _canonical(raw);
      _remember(key, canonical);
      return canonical;
    }
    final source = (raw['players'] as List? ?? const [])
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .where((row) => row['id'] == id)
        .firstOrNull;
    Snapshot fallback() {
      final original = Snapshot.unpresented(raw);
      media?.absorb(original);
      _remember(key, original);
      return original;
    }

    if (source == null || !adjudicatedAliasMatches(decision, source)) {
      return fallback();
    }
    try {
      final target = await _loadSnapshot(
        'entity:player:${decision.visibleId}',
        '/v1/entity',
        queryParameters: {'type': 'player', 'id': decision.visibleId},
      );
      if (media?.revokedDisplayAliases.contains(id) == true) {
        return fallback();
      }
      final visible = target.player(decision.visibleId);
      if (visible == null ||
          !adjudicatedVisibleMatches(decision, visible.json) ||
          !adjudicatedPairCompatible(source, visible.json)) {
        return fallback();
      }
      final resolved = target.withDisplayRedirect(
        id,
        decision.visibleId,
        fallback: raw,
      );
      media?.absorb(resolved);
      _remember(key, resolved);
      return resolved;
    } catch (_) {
      // A missing/changed target never turns an alias deep link into a 404.
      return fallback();
    }
  }

  /// One page of a team's matches across every competition (#150). One
  /// attempt: the profile already shows its own matches meanwhile.
  Future<TeamMatchesPage> loadTeamMatches(
    String teamId,
    String bucket, {
    String? cursor,
    int limit = teamMatchesPageSize,
    String? competitionId,
    String? season,
  }) async => TeamMatchesPage(
    await _getJson(
      '/v1/team-matches',
      queryParameters: {
        'id': teamId,
        'bucket': bucket,
        'cursor': ?cursor,
        'limit': limit,
        'competitionId': ?competitionId,
        if (competitionId != null) 'season': ?season,
      },
      maxAttempts: 1,
    ),
  );

  /// The team's real (competition, season) options and the selected one's
  /// exact table (#161). One attempt: the profile falls back to its own
  /// snapshot when it fails.
  Future<TeamContext> loadTeamContext(
    String teamId, {
    String? competitionId,
    String? season,
  }) async => TeamContext(
    await _getJson(
      '/v1/team-context',
      queryParameters: {
        'id': teamId,
        'competitionId': ?competitionId,
        if (competitionId != null) 'season': ?season,
      },
      maxAttempts: 1,
    ),
  );

  Future<Snapshot> loadMatchContext(String id) => _loadSnapshot(
    'match-context:$id',
    '/v1/match-context',
    queryParameters: {'id': id},
  );

  /// Recent form + head-to-head (DB-only on the server: never registers
  /// demand nor calls a provider). One attempt: it is optional content.
  Future<MatchPreview> loadMatchPreview(String id) async => MatchPreview(
    await _getJson(
      '/v1/match-preview',
      queryParameters: {'id': id},
      maxAttempts: 1,
    ),
  );

  /// One page of the pair's stored head-to-head (#155). `extend` asks the
  /// server to extend both teams' central coverage one step back (never a
  /// provider call from the app). One attempt: optional content.
  Future<H2hPage> loadMatchH2h(
    String id, {
    String scope = 'all',
    String? cursor,
    int limit = 20,
    bool extend = false,
  }) async => H2hPage(
    await _getJson(
      '/v1/match-h2h',
      queryParameters: {
        'id': id,
        'scope': scope,
        'cursor': ?cursor,
        'limit': limit,
        if (extend) 'extend': '1',
      },
      maxAttempts: 1,
    ),
  );

  /// The two-letter code `/v1/explore` accepts, or null (global list).
  static String? exploreCountry(String? country) {
    final code = country?.trim().toUpperCase();
    return code != null && RegExp(r'^[A-Z]{2}$').hasMatch(code) ? code : null;
  }

  static String _exploreKey(String? code) =>
      code == null ? 'explore' : 'explore:$code';

  /// Suggestions. A selectable [country] adds that country's primary league,
  /// national team and league clubs ahead of the same global list (servers
  /// without the country lens ignore the parameter). Every answer is also
  /// kept on the device so the next session paints Explorar at once.
  Future<Snapshot> loadExplore({String? country, CancelToken? cancelToken}) {
    final code = exploreCountry(country);
    return _loadCatalog(
      _exploreKey(code),
      '/v1/explore',
      queryParameters: code != null ? {'country': code} : null,
      cancelToken: cancelToken,
      persist: true,
    );
  }

  /// The last Explorar answer for [country] (the global list when null) held
  /// in memory or on the device, whatever its age. Never a request.
  Future<Snapshot?> readStoredExplore(String? country) async {
    final key = _exploreKey(exploreCountry(country));
    final memory = _snapshotCache[key];
    if (memory != null) return memory;
    try {
      final stored = await database?.readCatalogEntry(key);
      if (stored == null) return null;
      final snapshot = _canonical(jsonDecode(stored.payload) as Json);
      // A response that landed meanwhile wins over the device copy.
      final landed = _snapshotCache[key];
      if (landed != null) return landed;
      // Not marked as fetched: it is shown, never served as fresh.
      _remember(key, snapshot);
      return snapshot;
    } catch (_) {
      // An unreadable/corrupt local row is replaced by the next response.
      return null;
    }
  }

  bool _exploreFresh(String? code) {
    final fetched = _catalogFetchedAt[_exploreKey(code)];
    return fetched != null &&
        DateTime.now().difference(fetched) < catalogMemoryTtl;
  }

  /// Explorar suggestions, progressively, so the first paint never waits for
  /// the network (field report: 10-20 s of an empty page on a first open).
  ///
  /// 1. The global request starts at once, before [country] is even known.
  /// 2. The country request starts as soon as [country] resolves: both run in
  ///    parallel and neither waits for the other.
  /// 3. The last stored answer (country, else global) paints immediately,
  ///    marked `revalidating`.
  /// 4. A quicker global answer replaces a missing/global placeholder, never
  ///    a country one; the country answer is final. If it fails, the global
  ///    answer is final; if both fail, the placeholder stays (marked stale)
  ///    or the stream ends in the error.
  Stream<Snapshot> watchExplore(
    Future<String?> country, {
    CancelToken? cancelToken,
  }) async* {
    final global = _settle(loadExplore(cancelToken: cancelToken));
    String? code;
    try {
      code = exploreCountry(await country);
    } catch (_) {
      code = null;
    }
    final local = code == null
        ? null
        : _settle(loadExplore(country: code, cancelToken: cancelToken));
    Snapshot? shown;
    var shownLocal = false;
    if (!_exploreFresh(code)) {
      final cachedLocal = code == null ? null : await readStoredExplore(code);
      final cached = cachedLocal ?? await readStoredExplore(null);
      if (cached != null) {
        shown = cached;
        shownLocal = cachedLocal != null;
        yield cached.withFreshness(revalidating: true);
      }
    }
    if (local != null) {
      final globalFirst = await Future.any([
        local.then((_) => false),
        global.then((_) => true),
      ]);
      if (globalFirst && !shownLocal) {
        final value = (await global).value;
        if (value != null) {
          shown = value;
          yield value.withFreshness(revalidating: true);
        }
      }
      final answer = await local;
      if (answer.value != null) {
        yield answer.value!;
        return;
      }
      final fallback = (await global).value;
      if (fallback != null && !shownLocal) {
        yield fallback;
        return;
      }
      if (shown != null) {
        yield shown.asStale();
        return;
      }
      Error.throwWithStackTrace(answer.error!, answer.stack!);
    }
    final answer = await global;
    if (answer.value != null) {
      yield answer.value!;
      return;
    }
    if (shown != null) {
      yield shown.asStale();
      return;
    }
    Error.throwWithStackTrace(answer.error!, answer.stack!);
  }

  static Future<({Snapshot? value, Object? error, StackTrace? stack})> _settle(
    Future<Snapshot> request,
  ) => request.then(
    (value) => (value: value, error: null, stack: null),
    onError: (Object error, StackTrace stack) =>
        (value: null, error: error, stack: stack),
  );

  void _persistCatalog(String key, Json raw) {
    final db = database;
    if (db == null) return;
    // Never delays showing fresh data: memory already holds the snapshot.
    late final Future<void> write;
    write = db
        .saveCatalogSnapshot(key, jsonEncode(raw))
        .catchError((Object _) {})
        .whenComplete(() => _diskWrites.remove(write));
    _diskWrites.add(write);
  }

  Future<Snapshot> _loadCatalog(
    String key,
    String path, {
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    bool persist = false,
  }) async {
    final cached = _snapshotCache[key];
    final fetched = _catalogFetchedAt[key];
    // A partial answer (remote discovery pending) is never served from cache.
    if (cached != null &&
        !cached.pendingRemote &&
        fetched != null &&
        DateTime.now().difference(fetched) < catalogMemoryTtl) {
      return cached;
    }
    final raw = await _getJson(
      path,
      queryParameters: queryParameters,
      cancelToken: cancelToken,
      maxAttempts: 1,
    );
    final snapshot = _canonical(raw);
    _remember(key, snapshot);
    _catalogFetchedAt.removeWhere(
      (key, value) => !_snapshotCache.containsKey(key),
    );
    _catalogFetchedAt[key] = DateTime.now();
    if (persist && !snapshot.pendingRemote) _persistCatalog(key, raw);
    return snapshot;
  }

  Future<Snapshot> searchCatalog(
    String query,
    String? country, {
    CancelToken? cancelToken,
  }) {
    final normalizedQuery = query.trim().toLowerCase();
    final normalizedCountry = country?.trim().toUpperCase();
    if (normalizedQuery.length < 2) {
      return loadExplore(country: normalizedCountry, cancelToken: cancelToken);
    }
    return _loadCatalog(
      'search:$normalizedQuery:${normalizedCountry ?? ''}',
      '/v1/search',
      queryParameters: {
        'q': normalizedQuery,
        if (normalizedCountry != null && normalizedCountry.isNotEmpty)
          'country': normalizedCountry,
      },
      cancelToken: cancelToken,
    );
  }

  Future<Snapshot> loadFavorites(List<String> keys) {
    final normalizedKeys = [...keys]..sort();
    return _loadSnapshot(
      'favorites:${normalizedKeys.join(',')}',
      '/v1/favorites',
      queryParameters: {'keys': normalizedKeys.join(',')},
    );
  }

  @override
  Future<MatchDetail> loadMatchDetail(
    String id, {
    CancelToken? cancelToken,
  }) async {
    // First open this session: ONE request-aware call. The server returns the
    // persisted detail at once (partial or full) and only registers demand
    // when hydration is actually needed (deduplicated, never waits for the
    // provider). `available` (displayable) is not "complete".
    // Later opens are read-only unless the server says demand would help.
    if (_detailRequested.contains(id)) {
      final cached = await readMatchDetail(id, cancelToken: cancelToken);
      if (!cached.hydrationNeeded) return cached;
    }
    return _detailRequestInFlight.putIfAbsent(id, () async {
      try {
        final detail = MatchDetail(
          await _getJson(
            '/v1/match-detail',
            queryParameters: {'id': id},
            maxAttempts: 1,
            cancelToken: cancelToken,
          ),
          blockedAliasIds: media?.revokedDisplayAliases ?? const {},
        );
        // Remember accepted requests only. Errors/timeouts remain retryable.
        _detailRequested.add(id);
        return detail;
      } finally {
        _detailRequestInFlight.remove(id);
      }
    });
  }

  Future<MatchDetail> readMatchDetail(
    String id, {
    CancelToken? cancelToken,
  }) async => MatchDetail(
    await _getJson(
      '/v1/match-detail',
      queryParameters: {'id': id, 'request': '0'},
      maxAttempts: 1,
      cancelToken: cancelToken,
    ),
    blockedAliasIds: media?.revokedDisplayAliases ?? const {},
  );

  /// Tabla v2 "Forma" (#158), loaded only when the user opens it. DB-only on
  /// the server. One attempt: the table itself is already on screen.
  /// [until]: a published table's updatedAt, so the chips never show a
  /// result its J/Pts do not include yet.
  Future<StandingsForm> loadStandingsForm(
    String competitionId,
    String season, {
    String? until,
  }) async => StandingsForm(
    await _getJson(
      '/v1/standings-form',
      queryParameters: {
        'competitionId': competitionId,
        'season': season,
        'until': ?until,
      },
      maxAttempts: 1,
    ),
  );
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
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 15),
    ),
  );

  ref.onDispose(() => dio.close(force: true));
  return ApiRepository(
    dio,
    ref.watch(databaseProvider),
    const CalendarCachePolicy(),
    ref.watch(entityMediaProvider),
  );
});

/// Session memory of verified entity media (see [EntityMediaMemory]).
final entityMediaProvider = Provider<EntityMediaMemory>((ref) {
  final memory = EntityMediaMemory();
  ref.onDispose(memory.dispose);
  return memory;
});

/// Emits only when a presentation adjudication is revoked or superseded.
/// Screens re-present their already-emitted snapshots without refetching GOAL
/// or invalidating unrelated network providers.
final playerDisplayBlockedAliasesProvider = StreamProvider<Set<String>>((ref) {
  final memory = ref.watch(entityMediaProvider);
  final controller = StreamController<Set<String>>();
  var last = memory.revokedDisplayAliases;
  controller.add(last);
  void onChange() {
    final next = memory.revokedDisplayAliases;
    if (next.length == last.length) return;
    last = next;
    controller.add(next);
  }

  memory.addListener(onChange);
  ref.onDispose(() {
    memory.removeListener(onChange);
    controller.close();
  });
  return controller.stream;
});

/// Re-present an already-delivered snapshot when session evidence changes.
/// Calling this in a widget build subscribes it to revocations without a
/// fresh network read and restores hidden rows from Snapshot's source JSON.
Snapshot presentSnapshotForSession(WidgetRef ref, Snapshot snapshot) =>
    snapshot.withBlockedAliases(
      ref.watch(playerDisplayBlockedAliasesProvider).asData?.value ??
          ref.read(entityMediaProvider).revokedDisplayAliases,
    );

final snapshotProvider = FutureProvider<Snapshot>(
  (ref) => ref.watch(repositoryProvider).load(),
);

final calendarSnapshotProvider = StreamProvider.autoDispose
    .family<Snapshot, DateTime>((ref, date) {
      // Watched synchronously so the view can peek the memory cache in the
      // first frame of a date switch.
      final repository = ref.watch(repositoryProvider);
      if (repository is! ApiRepository) {
        return Stream.fromFuture(repository.loadDate(date));
      }
      final token = CancelToken();
      Timer? timer;
      var disposed = false;
      ref.onDispose(() {
        disposed = true;
        token.cancel('Calendar date closed');
        timer?.cancel();
      });
      return () async* {
        var hasData = false;
        try {
          await for (final snapshot in repository.watchDate(
            date,
            cancelToken: token,
          )) {
            if (!snapshot.calendarPending) hasData = true;
            yield snapshot;
          }
        } finally {
          // Revalidate only a date that has data, with backoff after failures.
          // A date that never got a snapshot ends in an error with Retry: it
          // is not restarted on a timer (no endless loading loop).
          if (!disposed && hasData) {
            timer = Timer(
              repository.calendarRevalidateDelay(date),
              ref.invalidateSelf,
            );
          }
        }
      }();
      // The repository bounds its own retries (visible deadline); Riverpod's
      // automatic error retry would restart a failed date forever.
    }, retry: (_, _) => null);

/// Device clock, injectable for tests.
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// A profile re-opened at least this long after its last answer revalidates
/// (see [revalidateEntitySnapshot]).
const entityRevalidateAfter = Duration(seconds: 30);

/// When each `/v1/entity` answer of this session was received (device
/// clock). Session memory, written only by [entitySnapshotProvider].
final entitySnapshotReceivedAtProvider =
    Provider<Map<({String type, String id}), DateTime>>((ref) => {});

/// Kept for the session (not autoDispose) so a re-opened profile paints its
/// last answer at once; [revalidateEntitySnapshot] refreshes it on re-entry.
final entitySnapshotProvider =
    FutureProvider.family<Snapshot, ({String type, String id})>((
      ref,
      request,
    ) async {
      final repository = ref.watch(repositoryProvider);
      final snapshot = repository is ApiRepository
          ? await repository.loadEntity(request.type, request.id)
          : await repository.load();
      if (ref.mounted) {
        ref.read(entitySnapshotReceivedAtProvider)[request] = ref.read(
          clockProvider,
        )();
      }
      return snapshot;
    });

/// Called when a profile screen is (re-)entered: an answer already held for
/// [request] that is at least [entityRevalidateAfter] old is refreshed in
/// the background. The old answer stays on screen meanwhile (instant paint;
/// a failed refresh keeps it, see `_loadSnapshot`), so server changes (e.g. a
/// deduplicated squad) appear without restarting the app. Returns whether a
/// refresh started.
bool revalidateEntitySnapshot(
  WidgetRef ref,
  ({String type, String id}) request,
) {
  if (!ref.exists(entitySnapshotProvider(request))) return false;
  final received = ref.read(entitySnapshotReceivedAtProvider)[request];
  if (received == null) return false;
  final age = ref.read(clockProvider)().difference(received);
  if (age < entityRevalidateAfter) return false;
  ref.invalidate(entitySnapshotProvider(request));
  return true;
}

/// Explorar/onboarding suggestions: the stored last answer at once, then the
/// network (see [ApiRepository.watchExplore]). Kept one minute after the
/// last listener leaves.
final exploreSnapshotProvider = StreamProvider.autoDispose<Snapshot>((ref) {
  final repository = ref.watch(repositoryProvider);
  final token = CancelToken();
  ref.onDispose(() => token.cancel('Explore closed'));
  void keepForAMinute() {
    if (!ref.mounted) return;
    final link = ref.keepAlive();
    final expiry = Timer(const Duration(minutes: 1), link.close);
    ref.onDispose(expiry.cancel);
  }

  if (repository is! ApiRepository) {
    return Stream.fromFuture(
      repository.load().then((value) {
        keepForAMinute();
        return value;
      }),
    );
  }
  // Country only lifts local suggestions; without one (or if the local
  // preference is unavailable) the global list is still served. The global
  // request never waits for it.
  final country = ref
      .watch(preferenceProvider.selectAsync((p) => p.effectiveCountry))
      .timeout(const Duration(seconds: 2))
      .then<String?>((value) => value, onError: (Object _) => null);
  return () async* {
    yield* repository.watchExplore(country, cancelToken: token);
    keepForAMinute();
  }();
});

final searchSnapshotProvider = FutureProvider.autoDispose
    .family<Snapshot, ({String query, String? country})>((ref, request) async {
      final repository = ref.watch(repositoryProvider);
      final token = CancelToken();
      ref.onDispose(() => token.cancel('Search superseded'));
      if (repository is ApiRepository) {
        return repository.searchCatalog(
          request.query,
          request.country,
          cancelToken: token,
        );
      }
      return repository.load();
    });

final favoritesSnapshotProvider = FutureProvider.family<Snapshot, String>((
  ref,
  encodedKeys,
) async {
  final repository = ref.watch(repositoryProvider);
  if (repository is ApiRepository) {
    final keys = encodedKeys
        .split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    return repository.loadFavorites(keys);
  }
  return repository.load();
});

/// Settled match data stays cached for this long after it loads, so leaving
/// and re-entering a match shortly after does not refetch it.
const matchCacheRetention = Duration(minutes: 1);

void _retainSettled(Ref ref) {
  final link = ref.keepAlive();
  final expiry = Timer(matchCacheRetention, link.close);
  ref.onDispose(expiry.cancel);
}

final matchContextSnapshotProvider = FutureProvider.autoDispose
    .family<Snapshot, String>((ref, id) async {
      final repository = ref.watch(repositoryProvider);
      final value = await (repository is ApiRepository
          ? repository.loadMatchContext(id)
          : repository.load());
      // Data still arriving is re-read, never pinned by the retention cache.
      if (ref.mounted && !value.standingsPending) _retainSettled(ref);
      return value;
    });

/// Recent form + head-to-head of a match, loaded after (and independently
/// of) the match context: it never blocks the header or the tabs, fails on
/// its own, and is read once per open (no polling; tab switches and context
/// refreshes do not re-read it).
final matchPreviewProvider = FutureProvider.autoDispose
    .family<MatchPreview, String>((ref, id) async {
      final repository = ref.watch(repositoryProvider);
      if (repository is! ApiRepository) return MatchPreview.empty(id);
      final value = await repository.loadMatchPreview(id);
      if (ref.mounted) _retainSettled(ref);
      return value;
      // No automatic retries: a failure stays a quiet error state (manual
      // "Reintentar" in Cara a cara only).
    }, retry: (_, _) => null);

/// First read-only recheck after the open. The provider usually answers in
/// ~1 s once the worker is woken, so rechecks start early (reads only: never
/// a provider request).
final detailPollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 2),
);

/// Bounded, growing read-only refreshes while the server reports pending
/// sections (5 s, 10 s, 20 s, 40 s by default), then stop.
final detailPollScheduleProvider = Provider<List<Duration>>((ref) {
  final base = ref.watch(detailPollIntervalProvider);
  // 2, 4, 8, 15, 40 s by default: the last read lands ~69 s after the open,
  // clearly after the worker's 1-minute cron fallback (+ ~1 s GOAL + write
  // latency) when a debounced wake-up was skipped. Then a stable state.
  // Finite: 5 read-only rechecks at most.
  return [base, base * 2, base * 4, base * 7.5, base * 20];
});

/// Upper bound for any single detail read.
final detailReadTimeoutProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 5),
);

/// Last good detail per match for this app session. A refresh (retry,
/// re-entry) starts from it instead of an empty "loading" state, so arriving
/// data never flickers away and a failed refresh never erases a lineup.
final matchDetailMemoryProvider = Provider<Map<String, MatchDetail>>(
  (ref) => <String, MatchDetail>{},
);

/// Most recently opened matches kept in [matchDetailMemoryProvider].
const matchDetailMemoryLimit = 30;

int _detailLevelRank(String level) => switch (level) {
  'full' => 3,
  'partial' => 2,
  'live' => 1,
  _ => 0,
};

dynamic _longerList(dynamic current, dynamic next) {
  final currentLength = current is List ? current.length : 0;
  final nextLength = next is List ? next.length : 0;
  return nextLength >= currentLength ? next : current;
}

dynamic _latestNonEmptyList(dynamic current, dynamic next) =>
    next is List && next.isNotEmpty ? next : current;

dynamic _latestNonEmpty(dynamic current, dynamic next) {
  if (next == null) return current;
  if (next is String && next.trim().isEmpty) return current;
  return next;
}

bool _hasLineupPlayers(Json side) =>
    (side['starters'] is List && (side['starters'] as List).isNotEmpty) ||
    (side['substitutes'] is List && (side['substitutes'] as List).isNotEmpty);

dynamic _mergeCoach(
  Json current,
  Json next, {
  required bool acceptNextPlayers,
}) {
  if (_hasLineupPlayers(next)) {
    return acceptNextPlayers ? next['coach'] : current['coach'];
  }
  final nextCoach = next['coach'];
  return nextCoach is Map && nextCoach.isNotEmpty
      ? nextCoach
      : current['coach'];
}

List<String> _lineupPlayerKeys(Json player, {String nameScope = ''}) {
  final keys = <String>[];
  for (final field in const ['canonicalId', 'id']) {
    final value = player[field]?.toString().trim();
    if (value != null && value.isNotEmpty) keys.add('$field:$value');
  }
  final name = player['name']?.toString().trim().toLowerCase() ?? '';
  if (name.isNotEmpty) keys.add('name:$nameScope:$name');
  return keys;
}

bool _compatibleLineupIdentity(Json remembered, Json next) {
  final rememberedCanonical = remembered['canonicalId']?.toString().trim();
  final nextCanonical = next['canonicalId']?.toString().trim();
  if (rememberedCanonical?.isNotEmpty == true &&
      nextCanonical?.isNotEmpty == true) {
    return rememberedCanonical == nextCanonical;
  }
  final rememberedId = remembered['id']?.toString().trim();
  final nextId = next['id']?.toString().trim();
  if (rememberedId?.isNotEmpty == true && nextId?.isNotEmpty == true) {
    return rememberedId == nextId;
  }
  return true;
}

dynamic _authoritativePlayerList(
  dynamic current,
  dynamic next, {
  required String nameScope,
}) {
  if (next is! List) return <dynamic>[];
  final remembered = <String, Json>{};
  final ambiguousNames = <String>{};
  if (current is List) {
    for (final item in current.whereType<Map>()) {
      final player = Map<String, dynamic>.from(item);
      for (final key in _lineupPlayerKeys(
        player,
        nameScope: player['_memorySide']?.toString() ?? '',
      )) {
        if (ambiguousNames.contains(key)) continue;
        if (key.startsWith('name:') && remembered.containsKey(key)) {
          remembered.remove(key);
          ambiguousNames.add(key);
          continue;
        }
        remembered.putIfAbsent(key, () => player);
      }
    }
  }
  return next.map((item) {
    if (item is! Map) return item;
    final player = Map<String, dynamic>.from(item);
    Json? previous;
    final keys = _lineupPlayerKeys(player, nameScope: nameScope);
    final stableKeys = keys.where((key) => !key.startsWith('name:'));
    for (final key in stableKeys) {
      previous = remembered[key];
      if (previous != null && !_compatibleLineupIdentity(previous, player)) {
        previous = null;
        continue;
      }
      if (previous != null) break;
    }
    if (previous == null) {
      final nameKey = keys.where((key) => key.startsWith('name:')).firstOrNull;
      final byName = nameKey == null ? null : remembered[nameKey];
      final rememberedHasStable =
          byName != null &&
          _lineupPlayerKeys(byName).any((key) => !key.startsWith('name:'));
      if (stableKeys.isEmpty || !rememberedHasStable) previous = byName;
    }
    if (previous == null) return player;
    for (final field in const ['canonicalId', 'image', 'media']) {
      final value = player[field];
      final absent = value == null || (value is String && value.trim().isEmpty);
      if (absent && previous[field] != null) player[field] = previous[field];
    }
    return player;
  }).toList();
}

Json _mergeDetailSide(
  Json current,
  Json next, {
  required bool replaceExisting,
  required List<dynamic> rememberedPlayers,
  required String side,
}) {
  final nextHasPlayers = _hasLineupPlayers(next);
  final acceptNextPlayers =
      nextHasPlayers && (replaceExisting || !_hasLineupPlayers(current));
  return {
    ...current,
    ...next,
    'formation':
        acceptNextPlayers ||
            current['formation'] == null ||
            (current['formation'] is String &&
                (current['formation'] as String).trim().isEmpty)
        ? _latestNonEmpty(current['formation'], next['formation'])
        : current['formation'],
    'starters': acceptNextPlayers
        ? _authoritativePlayerList(
            rememberedPlayers,
            next['starters'],
            nameScope: side,
          )
        : current['starters'],
    'substitutes': acceptNextPlayers
        ? _authoritativePlayerList(
            rememberedPlayers,
            next['substitutes'],
            nameScope: side,
          )
        : current['substitutes'],
    'missing': _longerList(current['missing'], next['missing']),
    'coach': _mergeCoach(current, next, acceptNextPlayers: acceptNextPlayers),
  };
}

bool _hasVisibleLineup(Json home, Json away) {
  bool sideHasData(Json side) =>
      _hasLineupPlayers(side) ||
      (side['coach'] is Map && (side['coach'] as Map).isNotEmpty);
  return sideHasData(home) || sideHasData(away);
}

/// Merges persisted detail monotonically while taking liveness from the
/// latest answer. Rechecks may add data, but never erase richer UI state.
MatchDetail _monotonicDetail(MatchDetail current, MatchDetail next) {
  if (!current.available) return next;
  // Merge untouched provider rows; presentation may have hidden an alias row
  // that must be restorable if the adjudication is revoked later.
  final currentRaw = current.sourceJson;
  final nextRaw = next.sourceJson;
  Json side(Json detail, String key) =>
      detail[key] is Map ? Map<String, dynamic>.from(detail[key] as Map) : {};
  final currentHome = side(currentRaw, 'home');
  final currentAway = side(currentRaw, 'away');
  final nextHome = side(nextRaw, 'home');
  final nextAway = side(nextRaw, 'away');
  final replaceExisting =
      _detailLevelRank(next.detailLevel) >=
      _detailLevelRank(current.detailLevel);
  final rememberedPlayers = <dynamic>[
    for (final player
        in currentHome['starters'] is List
            ? currentHome['starters'] as List
            : const [])
      if (player is Map) {...player, '_memorySide': 'home'},
    for (final player
        in currentHome['substitutes'] is List
            ? currentHome['substitutes'] as List
            : const [])
      if (player is Map) {...player, '_memorySide': 'home'},
    for (final player
        in currentAway['starters'] is List
            ? currentAway['starters'] as List
            : const [])
      if (player is Map) {...player, '_memorySide': 'away'},
    for (final player
        in currentAway['substitutes'] is List
            ? currentAway['substitutes'] as List
            : const [])
      if (player is Map) {...player, '_memorySide': 'away'},
  ];
  final home = _mergeDetailSide(
    currentHome,
    nextHome,
    replaceExisting: replaceExisting,
    rememberedPlayers: rememberedPlayers,
    side: 'home',
  );
  final away = _mergeDetailSide(
    currentAway,
    nextAway,
    replaceExisting: replaceExisting,
    rememberedPlayers: rememberedPlayers,
    side: 'away',
  );
  final currentStatistics = current.json['statistics'];
  final statistics =
      !replaceExisting &&
          currentStatistics is List &&
          currentStatistics.isNotEmpty
      ? currentStatistics
      : _latestNonEmptyList(currentStatistics, next.json['statistics']);
  final videos = next.sectionState('videos') == 'unavailable'
      ? current.json['videos']
      : next.json['videos'];
  final coverage = <String, dynamic>{
    ...?current.coverage,
    ...?next.coverage,
    'lineupEnrichmentPending': next.lineupEnrichmentPending,
  };
  if (_hasVisibleLineup(home, away)) coverage['lineup'] = 'available';
  if (statistics is List && statistics.isNotEmpty) {
    coverage['statistics'] = 'available';
  }
  final detailLevel = replaceExisting ? next.detailLevel : current.detailLevel;
  return MatchDetail(
    {
      ...currentRaw,
      ...nextRaw,
      'available': true,
      'detailLevel': detailLevel,
      'stadium': _latestNonEmpty(current.json['stadium'], next.json['stadium']),
      'referee': _latestNonEmpty(current.json['referee'], next.json['referee']),
      'round': _latestNonEmpty(current.json['round'], next.json['round']),
      'stage': _latestNonEmpty(current.json['stage'], next.json['stage']),
      'home': home,
      'away': away,
      'statistics': statistics,
      // P0-A: the incidents list is the provider's current answer (a
      // corrected or annulled goal, a deleted card): a present list replaces,
      // even when shorter or empty; only a missing section keeps the old one.
      'incidents': next.available && next.json['incidents'] is List
          ? next.json['incidents']
          : current.json['incidents'],
      'videos': videos,
      'pending': next.pending,
      'hydrationNeeded': next.hydrationNeeded,
      'coverage': coverage,
    },
    blockedAliasIds: {...current.blockedAliasIds, ...next.blockedAliasIds},
  );
}

final matchDetailProvider = StreamProvider.autoDispose
    .family<MatchDetail, String>((ref, id) async* {
      final repository = ref.watch(repositoryProvider);
      final memory = ref.watch(matchDetailMemoryProvider);
      final readTimeout = ref.read(detailReadTimeoutProvider);
      var disposed = false;
      Timer? timer;
      Completer<void>? waiting;
      var requestToken = CancelToken();
      ref.onDispose(() {
        disposed = true;
        timer?.cancel();
        requestToken.cancel('Match Center closed');
        if (waiting != null && !waiting.isCompleted) waiting.complete();
      });
      void remember(MatchDetail detail) {
        if (!detail.available) return;
        // Small LRU: the most recently opened matches only.
        memory
          ..remove(id)
          ..[id] = detail;
        while (memory.length > matchDetailMemoryLimit) {
          memory.remove(memory.keys.first);
        }
      }

      // Cache-first: the last good detail (if any) is shown immediately.
      final blockedAliases = repository is ApiRepository
          ? repository.media?.revokedDisplayAliases ?? const <String>{}
          : const <String>{};
      var current =
          memory[id]?.withBlockedAliases(blockedAliases) ??
          MatchDetail.waiting(id);
      yield current;
      if (disposed) return;
      try {
        final loaded =
            await (repository is ApiRepository
                    ? repository.loadMatchDetail(id, cancelToken: requestToken)
                    : repository.loadMatchDetail(id))
                .timeout(
                  readTimeout,
                  onTimeout: () {
                    requestToken.cancel('Initial detail deadline');
                    throw TimeoutException('Initial detail deadline');
                  },
                );
        current = _monotonicDetail(current, loaded);
        remember(current);
      } catch (_) {
        // A failed read is not evidence that data is absent: keep what we
        // had and try bounded read-only refreshes.
        final currentBlocked = repository is ApiRepository
            ? repository.media?.revokedDisplayAliases ?? const <String>{}
            : const <String>{};
        current =
            memory[id]?.withBlockedAliases(currentBlocked) ??
            MatchDetail.waiting(id);
      }
      if (disposed) return;
      yield current;

      if (repository is! ApiRepository) {
        if (current.pending) {
          yield current.withPending(false);
        }
        return;
      }

      for (final delay in ref.read(detailPollScheduleProvider)) {
        if (!current.pending) break;
        waiting = Completer<void>();
        timer = Timer(delay, () => waiting!.complete());
        await waiting.future;
        if (disposed) return;
        try {
          requestToken = CancelToken();
          final next = await repository
              .readMatchDetail(id, cancelToken: requestToken)
              .timeout(
                readTimeout,
                onTimeout: () {
                  requestToken.cancel('Detail read deadline');
                  throw TimeoutException('Detail read deadline');
                },
              );
          if (disposed) return;
          current = _monotonicDetail(current, next);
          remember(current);
          yield current;
        } catch (_) {
          // Retain the latest detail; the schedule stays bounded.
        }
      }
      // Complete by the server's own view (not just "displayable").
      final complete = !current.pending && !current.hydrationNeeded;
      if (!disposed && current.pending) {
        current = current.withPending(false);
        yield current;
      }
      // Retain only real, complete detail; an incomplete one is re-read on
      // the next visit.
      if (!disposed && current.available && complete) _retainSettled(ref);
    });

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
      .whenData(
        (snapshot) => snapshot
            .withBlockedAliases(
              ref.watch(playerDisplayBlockedAliasesProvider).asData?.value ??
                  ref.read(entityMediaProvider).revokedDisplayAliases,
            )
            .withLiveUpdates(updates),
      );
});

final effectiveCalendarSnapshotProvider = Provider.autoDispose
    .family<AsyncValue<Snapshot>, DateTime>((ref, date) {
      final updates =
          ref.watch(liveMatchUpdatesProvider).asData?.value ??
          const <String, LiveMatchUpdate>{};
      return ref
          .watch(calendarSnapshotProvider(date))
          .whenData(
            (snapshot) => snapshot
                .withBlockedAliases(
                  ref
                          .watch(playerDisplayBlockedAliasesProvider)
                          .asData
                          ?.value ??
                      ref.read(entityMediaProvider).revokedDisplayAliases,
                )
                .withLiveUpdates(updates),
          );
    });

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

/// Followed `type:id` keys, each resolved to its canonical entity through the
/// redirects seen this session (see [EntityRedirectMemory]): a follow stored
/// under an alias id (e.g. the legacy `fb_comp_cr`) reads as the canonical
/// entity everywhere follows are shown or used (Siguiendo, the Favoritos feed
/// group, star buttons, relevance). Read-time only: what is stored and synced
/// is never rewritten. Re-emits when a new redirect is learned.
final followsProvider = StreamProvider<Set<String>>((ref) {
  final redirects = ref.watch(entityMediaProvider).redirects;
  final controller = StreamController<Set<String>>();
  Set<String>? stored;
  void emit() {
    final value = stored;
    if (value == null || controller.isClosed) return;
    controller.add({for (final key in value) redirects.resolveFollowKey(key)});
  }

  final subscription = ref.watch(databaseProvider).watchFollows().listen((
    value,
  ) {
    stored = value;
    emit();
  }, onError: controller.addError);
  redirects.addListener(emit);
  ref.onDispose(() {
    redirects.removeListener(emit);
    subscription.cancel();
    controller.close();
  });
  return controller.stream;
});

/// Follows or unfollows [type]:[id]. Unfollowing also removes every stored
/// key that resolves to the same canonical entity (an alias follow), so the
/// star never stays on after the user turned it off.
Future<void> toggleFollow(
  AppDatabase database,
  EntityRedirectMemory redirects,
  String type,
  String id,
) async {
  if (type == 'match') return database.toggle(type, id);
  final canonical = redirects.resolve(id);
  final aliases = {
    for (final alias in redirects.redirects.keys)
      if (redirects.resolve(alias) == canonical) alias,
  };
  // No alias known for this entity: the plain toggle.
  if (canonical == id && aliases.isEmpty) return database.toggle(type, id);
  await database.toggleAny(type, canonical, {id, ...aliases});
}

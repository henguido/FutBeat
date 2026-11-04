import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'models.dart';

// A DELETE with only the primary key carries no ordering evidence of its own.
// A known version can reject an older replay, without preventing a genuinely
// newer incarnation (whose revision may restart) or a new provider.
bool _predatesLiveDeletion(LiveMatchUpdate update, Json deleted) {
  final changedAt = DateTime.tryParse(deleted['changed_at'] as String? ?? '');
  if (changedAt == null) return false;
  if (update.changedAt.isBefore(changedAt)) return true;
  final revision = deleted['revision'];
  return update.changedAt.isAtSameMomentAs(changedAt) &&
      update.provider == deleted['provider'] &&
      revision is num &&
      update.revision <= revision;
}

// Content revision and provider observation are separate clocks. Replays of
// unchanged content must not regress the latest confirmed observation.
bool _olderLiveObservation(LiveMatchUpdate update, LiveMatchUpdate previous) {
  if (update.provider != previous.provider ||
      update.revision != previous.revision ||
      !update.changedAt.isAtSameMomentAs(previous.changedAt)) {
    return false;
  }
  final incoming = update.observedAt ?? update.changedAt;
  final existing = previous.observedAt ?? previous.changedAt;
  if (incoming.isBefore(existing)) return true;
  return incoming.isAtSameMomentAs(existing) &&
      update.receivedAt != null &&
      previous.receivedAt != null &&
      update.receivedAt!.isBefore(previous.receivedAt!);
}

/// [serverNow] is the REST response's server time (HTTP `Date`) and
/// [deviceNow] the device time it arrived; together they give every row a
/// skew-free receipt time (#120: an old LIVE row never looks fresh).
///
/// Absence only means "deleted on the server" when the answer is [complete]
/// (every page read). With [removableSince] (server time, compared with
/// [LiveMatchUpdate.changedAt]) the request covered only rows changed since
/// then: an overlay whose last change is older was simply not asked for, so
/// it is kept. [stateBeforeRequest] also protects a pre-existing key updated
/// by Realtime while the REST pages were being read. A partial answer never
/// removes anything.
/// [deletedDuringRequest] protects realtime DELETE frames from a REST page
/// captured before that deletion. A later bootstrap may authoritatively read
/// the key again; these tombstones only live for the in-flight request.
Map<String, LiveMatchUpdate> reconcileLiveBootstrapSnapshot(
  Map<String, LiveMatchUpdate> current,
  Iterable<Json> rows, {
  Set<String>? keysBeforeRequest,
  Map<String, LiveMatchUpdate>? stateBeforeRequest,
  Set<String> deletedDuringRequest = const {},
  Map<String, Json> deletedVersions = const {},
  DateTime? serverNow,
  DateTime? deviceNow,
  bool complete = true,
  DateTime? removableSince,
}) {
  final result = Map<String, LiveMatchUpdate>.of(current);
  final before =
      stateBeforeRequest?.keys.toSet() ??
      keysBeforeRequest ??
      current.keys.toSet();
  final fetched = <String>{};
  final arrivedAt = (deviceNow ?? DateTime.now()).toUtc();
  var canRemoveAbsent = complete;

  for (final row in rows) {
    // A malformed row is not proof of deletion. Preserve a readable match
    // identity even when another field cannot be parsed. Without an identity,
    // this batch cannot establish which pre-existing overlay was absent.
    final rowId = row['match_id'];
    if (rowId is String && rowId.startsWith('fb_')) {
      fetched.add(rowId);
    } else {
      canRemoveAbsent = false;
    }
    try {
      var update = LiveMatchUpdate.fromJson(
        row,
        receivedAt: LiveMatchUpdate.bootstrapReceivedAt(
          row,
          deviceNow: arrivedAt,
          serverNow: serverNow,
        ),
      );
      if (!update.matchId.startsWith('fb_')) continue;
      fetched.add(update.matchId);
      if (deletedDuringRequest.contains(update.matchId)) continue;
      final deleted = deletedVersions[update.matchId];
      if (deleted != null && _predatesLiveDeletion(update, deleted)) continue;
      final previous = result[update.matchId];
      if (previous != null &&
          (update.changedAt.isBefore(previous.changedAt) ||
              (update.provider == previous.provider &&
                  update.revision < previous.revision) ||
              _olderLiveObservation(update, previous))) {
        continue;
      }
      // Same row already received live: keep its (later) local receipt.
      final previousAt = previous?.receivedAt;
      if (previous != null &&
          previous.provider == update.provider &&
          previous.revision == update.revision &&
          previousAt != null &&
          previousAt.isAfter(update.receivedAt!)) {
        update = LiveMatchUpdate.fromJson(row, receivedAt: previousAt);
      }
      result[update.matchId] = update;
    } catch (_) {
      // A malformed REST row must not erase the last valid state.
    }
  }

  if (!canRemoveAbsent) return result;
  result.removeWhere(
    (matchId, update) =>
        before.contains(matchId) &&
        !fetched.contains(matchId) &&
        // A Realtime frame may refresh an existing key after the REST cursor
        // passed it. Absence from REST must not erase that newer local frame.
        (stateBeforeRequest == null ||
            identical(update, stateBeforeRequest[matchId])) &&
        (removableSince == null ||
            !update.changedAt.toUtc().isBefore(removableSince.toUtc())),
  );
  return result;
}

/// How the REST bootstrap reads `live_match_updates`: only the rows whose
/// state CHANGED inside [window] (`changed_at`, indexed; `updated_at` is also
/// rewritten when nothing changed, days later). An older LIVE row is ignored
/// by the overlay after [LiveMatchUpdate.staleAfter]; an older terminal row is
/// already in the stored snapshots. Pages of [pageSize] by primary key (a
/// key never moves, so a row cannot be skipped by a concurrent update), far
/// below the PostgREST row cap (1000): a short page reliably means "last".
class LiveBootstrapPolicy {
  const LiveBootstrapPolicy({
    this.window = const Duration(hours: 72),
    this.pageSize = 250,
    this.maxPages = 40,
    this.removalMargin = const Duration(minutes: 30),
    this.joinedRefreshInterval = const Duration(minutes: 5),
  });

  final Duration window;
  final int pageSize;

  /// Safety bound (pageSize x maxPages rows); reaching it is a partial read.
  final int maxPages;

  /// Overlays whose last change is this close to the window start are never
  /// removed (boundary races): only rows clearly inside the window are.
  final Duration removalMargin;

  /// While the realtime channel is joined, the periodic REST check runs at
  /// most this often (realtime carries the changes; REST is the safety net).
  final Duration joinedRefreshInterval;
}

/// The columns [LiveMatchUpdate.fromJson] and the receipt time read.
const liveBootstrapColumns =
    'match_id,provider,external_match_id,status,minute,home_score,away_score,'
    'revision,event_count,latest_events,changed_at,updated_at';

/// One bootstrap read: the rows, whether every page was read, whether it
/// stopped at [LiveBootstrapPolicy.maxPages] (partial, but not worth an
/// immediate retry), and the server time of the last answer (HTTP `Date`).
typedef LiveBootstrapRead = ({
  List<Json> rows,
  bool complete,
  bool exhausted,
  DateTime? serverNow,
});

/// Reads the rows changed since [since] (server time) page by page (keyset on
/// `match_id`). A failure after some pages returns what was read as a
/// partial answer; a failure on the first page throws.
Future<LiveBootstrapRead> fetchLiveBootstrap(
  Dio dio,
  LiveRealtimeConfig config,
  LiveBootstrapPolicy policy, {
  required DateTime since,
  List<String>? matchIds,
  CancelToken? cancelToken,
}) async {
  if (matchIds != null && matchIds.isEmpty) {
    return (rows: <Json>[], complete: true, exhausted: false, serverNow: null);
  }
  final rows = <Json>[];
  DateTime? serverNow;
  String? after;
  LiveBootstrapRead partial({bool exhausted = false}) =>
      (rows: rows, complete: false, exhausted: exhausted, serverNow: serverNow);
  for (var page = 0; page < policy.maxPages; page++) {
    final Response<dynamic> response;
    try {
      response = await dio.getUri<dynamic>(
        config.bootstrapPageUri(
          since: since,
          after: after,
          limit: matchIds == null ? policy.pageSize : matchIds.length + 1,
          matchIds: matchIds,
        ),
        options: Options(headers: {'apikey': config.publicKey}),
        cancelToken: cancelToken,
      );
    } catch (_) {
      if (page == 0) rethrow;
      // The earlier page's Date is not paired with this later completion.
      // Without a current clock, partial rows use conservative stale age.
      serverNow = null;
      return partial();
    }
    // Reconciliation samples device time after all pages. Pair it with the
    // final response clock, or paging latency would refresh old LIVE rows.
    serverNow = null;
    try {
      final date = response.headers.value('date');
      if (date != null) serverNow = HttpDate.parse(date);
    } catch (_) {
      serverNow = null; // Missing/invalid current clock is already stale.
    }
    final data = response.data;
    if (data is! List) {
      if (page == 0) throw const FormatException('Unexpected LIVE bootstrap');
      return partial();
    }
    final pageRows = data
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
    rows.addAll(pageRows);
    // Dropping a malformed list entry does not make the remaining page a
    // complete snapshot. Its missing identity could belong to a local overlay.
    if (pageRows.length != data.length) return partial();
    if (data.length <
        (matchIds == null ? policy.pageSize : matchIds.length + 1)) {
      return (
        rows: rows,
        complete: true,
        exhausted: false,
        serverNow: serverNow,
      );
    }
    final last = pageRows.isEmpty ? null : pageRows.last['match_id'];
    if (last is! String || last == after) return partial();
    after = last;
  }
  return partial(exhausted: true);
}

class LiveRealtimeConfig {
  const LiveRealtimeConfig({
    required this.supabaseUrl,
    required this.publicKey,
  });

  factory LiveRealtimeConfig.fromEnvironment() {
    const configuredApiUrl = String.fromEnvironment('FUTBEAT_API_URL');
    const configuredSupabaseUrl = String.fromEnvironment(
      'FUTBEAT_SUPABASE_URL',
    );
    const configuredPublishableKey = String.fromEnvironment(
      'FUTBEAT_SUPABASE_PUBLISHABLE_KEY',
    );
    const legacyPublicToken = String.fromEnvironment(
      'FUTBEAT_API_PUBLIC_TOKEN',
    );

    // Publishable keys are client credentials by design. The Android/iOS app
    // gets the same public project configuration as the beta build even for a
    // plain local debug APK. Host-side Flutter tests stay unconfigured.
    final mobile = Platform.isAndroid || Platform.isIOS;
    return LiveRealtimeConfig.fromValues(
      apiUrl: configuredApiUrl.isNotEmpty
          ? configuredApiUrl
          : mobile
          ? 'https://izlmruqawgagwdcsjhte.supabase.co/functions/v1/futbeat-api'
          : '',
      supabaseUrl: configuredSupabaseUrl,
      publishableKey: configuredPublishableKey.isNotEmpty
          ? configuredPublishableKey
          : mobile
          ? 'sb_publishable_iSH4S3fKou_EEkdG3W_Azg_9E4HXzWE'
          : '',
      legacyPublicToken: legacyPublicToken,
    );
  }

  factory LiveRealtimeConfig.fromValues({
    String apiUrl = '',
    String supabaseUrl = '',
    String publishableKey = '',
    String legacyPublicToken = '',
  }) {
    final explicit = supabaseUrl.trim();
    final derived = explicit.isNotEmpty ? explicit : _originOf(apiUrl.trim());
    return LiveRealtimeConfig(
      supabaseUrl: derived.replaceFirst(RegExp(r'/+$'), ''),
      publicKey: publishableKey.trim().isNotEmpty
          ? publishableKey.trim()
          : legacyPublicToken.trim(),
    );
  }

  final String supabaseUrl;
  final String publicKey;

  bool get isConfigured => supabaseUrl.isNotEmpty && publicKey.isNotEmpty;

  Uri get restUri =>
      Uri.parse('$supabaseUrl/rest/v1/live_match_updates')
          .replace(queryParameters: const {'select': '*'});

  /// One bootstrap page: rows changed since [since] (server time), ordered
  /// by primary key, after the keyset cursor [after].
  Uri bootstrapPageUri({
    required DateTime since,
    required int limit,
    String? after,
    List<String>? matchIds,
  }) => Uri.parse('$supabaseUrl/rest/v1/live_match_updates').replace(
    queryParameters: {
      'select': liveBootstrapColumns,
      'changed_at': 'gte.${since.toUtc().toIso8601String()}',
      if (matchIds != null) 'match_id': 'in.(${matchIds.join(',')})',
      if (matchIds == null && after != null) 'match_id': 'gt.$after',
      'order': 'match_id.asc',
      'limit': '$limit',
    },
  );

  Uri get websocketUri {
    final base = Uri.parse(supabaseUrl);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/realtime/v1/websocket',
      queryParameters: {'apikey': publicKey, 'vsn': '1.0.0'},
    );
  }

  static String _originOf(String value) {
    if (value.isEmpty) return '';
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return '';
    return '${uri.scheme}://${uri.authority}';
  }
}

class LiveRealtimeClient {
  LiveRealtimeClient(
    this.config,
    this.dio, {
    this.retryDelay = const Duration(seconds: 2),
    this.refreshInterval = const Duration(seconds: 60),
    this.bootstrapPolicy = const LiveBootstrapPolicy(),
    this.scopedRealtime = false,
  });
  final LiveRealtimeConfig config;
  final Dio dio;
  final Duration retryDelay, refreshInterval;
  final LiveBootstrapPolicy bootstrapPolicy;

  /// The app uses scoped mode. Legacy callers may still use the unfiltered
  /// channel while migrating; tests exercise both paths.
  final bool scopedRealtime;
  static const maxRealtimeMatchIds = 100;
  final Map<String, Set<String>> _scopes = {};
  final StreamController<void> _scopeChanges = StreamController<void>.broadcast(
    sync: true,
  );
  final Set<Future<void> Function()> _refreshActiveScopes = {};
  final Set<void Function(bool)> _setActiveScopes = {};
  final Set<void Function()> _closeWatches = {};
  bool _appActive = true;

  /// Pause sport traffic while the app is not visible. Resume only the
  /// currently selected LIVE match scopes on return to the foreground.
  void setAppActive(bool active) {
    if (_appActive == active) return;
    _appActive = active;
    for (final setActive in List<void Function(bool)>.of(_setActiveScopes)) {
      setActive(active);
    }
  }

  /// Closes the gap left by Android suspending the socket in the background.
  /// The existing bootstrap reads only the currently visible match IDs.
  Future<void> refreshOnResume() async {
    await Future.wait([
      for (final refresh in List<Future<void> Function()>.of(
        _refreshActiveScopes,
      ))
        refresh(),
    ]);
  }

  /// A single socket carries at most 100 canonical match IDs. Open match
  /// scopes outrank the feed; REST remains the safety net for all other rows.
  List<String> get realtimeMatchIds {
    final ids = <String>{};
    int priority(String owner) => owner.startsWith('match:')
        ? 0
        : owner.startsWith('favorites:')
        ? 1
        : 2;
    final owners = _scopes.keys.toList()
      ..sort((a, b) {
        final byPriority = priority(a).compareTo(priority(b));
        return byPriority != 0 ? byPriority : a.compareTo(b);
      });
    for (final owner in owners) {
      for (final id in _scopes[owner]!) {
        if (RegExp(r'^fb_[A-Za-z0-9_-]+$').hasMatch(id)) ids.add(id);
        if (ids.length == maxRealtimeMatchIds) return ids.toList();
      }
    }
    return ids.toList();
  }

  void setScope(String owner, Iterable<String> matchIds) {
    if (_scopeChanges.isClosed) return;
    final next = matchIds.toSet();
    if (_scopes[owner]?.length == next.length &&
        _scopes[owner]!.containsAll(next)) {
      return;
    }
    _scopes[owner] = next;
    _scopeChanges.add(null);
  }

  void clearScope(String owner) {
    if (_scopeChanges.isClosed) return;
    if (_scopes.remove(owner) != null) _scopeChanges.add(null);
  }

  void dispose() {
    if (_scopeChanges.isClosed) return;
    _appActive = false;
    for (final close in List<void Function()>.of(_closeWatches)) {
      close();
    }
    _closeWatches.clear();
    _refreshActiveScopes.clear();
    _setActiveScopes.clear();
    _scopes.clear();
    _scopeChanges.close();
  }

  Stream<Map<String, LiveMatchUpdate>> watch() {
    final state = <String, LiveMatchUpdate>{};
    final deletedVersions = <String, Json>{};
    late StreamController<Map<String, LiveMatchUpdate>> controller;
    WebSocket? socket;
    Timer? retry, heartbeat, refresh, joinTimeout, scopeDebounce;
    StreamSubscription<void>? scopeSubscription;
    var disposed = false;
    var connecting = false;
    var sequence = 0;
    // One bootstrap at a time; a request during one runs once more after it
    // (e.g. the join right after the first read: closes the subscribe gap).
    var bootstrapping = false;
    var bootstrapAgain = false;
    var joined = false;
    var scopeVersion = 0;
    CancelToken? bootstrapToken;
    Set<String>? bootstrapDeletes;
    DateTime? lastBootstrap;
    // Server minus device clock, from the last answer's `Date`.
    var serverOffset = Duration.zero;
    late void Function() closeWatch;
    Future<void> Function()? refreshScope;
    void Function(bool)? setScopeActive;

    void rememberVersionFence(String id, Json row) {
      deletedVersions.remove(id);
      deletedVersions[id] = row;
      // Same bound for full DELETE and retired terminal overlay evidence.
      // Never retain an unbounded history of match IDs in one watch.
      final limit = scopedRealtime
          ? maxRealtimeMatchIds
          : bootstrapPolicy.pageSize * bootstrapPolicy.maxPages;
      while (deletedVersions.length > limit && deletedVersions.isNotEmpty) {
        deletedVersions.remove(deletedVersions.keys.first);
      }
    }

    void rememberRetiredTerminal(LiveMatchUpdate? previous) {
      if (previous == null ||
          (previous.status != 'VERIFIED' &&
              previous.status != 'FINISHED_PENDING_VERIFICATION')) {
        return;
      }
      rememberVersionFence(previous.matchId, {
        'changed_at': previous.changedAt.toIso8601String(),
        'provider': previous.provider,
        'revision': previous.revision,
      });
    }

    Future<void> stopWatch() async {
      if (disposed) return;
      disposed = true;
      deletedVersions.clear();
      _closeWatches.remove(closeWatch);
      _refreshActiveScopes.remove(refreshScope);
      _setActiveScopes.remove(setScopeActive);
      bootstrapToken?.cancel('LIVE listener closed');
      retry?.cancel();
      scopeDebounce?.cancel();
      heartbeat?.cancel();
      refresh?.cancel();
      joinTimeout?.cancel();
      await scopeSubscription?.cancel();
      await socket?.close();
    }

    closeWatch = () {
      unawaited(stopWatch());
      unawaited(controller.close());
    };

    void emit() {
      if (!disposed) {
        controller.add(
          Map.unmodifiable(Map<String, LiveMatchUpdate>.of(state)),
        );
      }
    }

    void accept(Json row) {
      // Delivery is not a new observation: replayed old rows stay old.
      // Use the same server/device mapping learned by REST. Comparing the
      // provider timestamp directly with the device clock falsely ages fresh
      // websocket frames (or makes old frames appear fresh) on a skewed device.
      final deviceNow = DateTime.now().toUtc();
      final update = LiveMatchUpdate.fromJson(
        row,
        receivedAt: LiveMatchUpdate.bootstrapReceivedAt(
          row,
          deviceNow: deviceNow,
          serverNow: deviceNow.add(serverOffset),
        ),
      );
      if (!update.matchId.startsWith('fb_')) return;
      final deleted = deletedVersions[update.matchId];
      if (deleted != null && _predatesLiveDeletion(update, deleted)) return;
      final previous = state[update.matchId];
      if (previous != null &&
          (update.changedAt.isBefore(previous.changedAt) ||
              (update.provider == previous.provider &&
                  update.revision < previous.revision) ||
              _olderLiveObservation(update, previous))) {
        return;
      }
      state[update.matchId] = update;
      deletedVersions.remove(update.matchId);
    }

    Future<void> bootstrapOnce() async {
      if (!_appActive) return;
      final requestedScopeVersion = scopeVersion;
      final ids = scopedRealtime ? realtimeMatchIds : null;
      if (ids != null && ids.isEmpty) return;
      final token = CancelToken();
      bootstrapToken = token;
      final deletedDuringRequest = <String>{};
      bootstrapDeletes = deletedDuringRequest;
      final before = scopedRealtime
          ? <String, LiveMatchUpdate>{
              for (final id in ids!)
                if (state.containsKey(id)) id: state[id]!,
            }
          : Map<String, LiveMatchUpdate>.of(state);
      final policy = bootstrapPolicy;
      final since = DateTime.now()
          .toUtc()
          .add(serverOffset)
          .subtract(policy.window);
      try {
        final read = await fetchLiveBootstrap(
          dio,
          config,
          policy,
          since: since,
          matchIds: ids,
          cancelToken: token,
        );
        if (disposed || !_appActive || requestedScopeVersion != scopeVersion) {
          return;
        }
        // The current scope changes before its debounced socket reconnect.
        // Do not reconcile a response for the previous set in that interval.
        if (ids != null) {
          final activeIds = realtimeMatchIds.toSet();
          if (activeIds.length != ids.length || !activeIds.containsAll(ids)) {
            return;
          }
        }
        final deviceNow = DateTime.now().toUtc();
        final serverNow = read.serverNow;
        if (serverNow != null) serverOffset = serverNow.difference(deviceNow);
        final reconciled = reconcileLiveBootstrapSnapshot(
          state,
          read.rows,
          stateBeforeRequest: before,
          deletedDuringRequest: deletedDuringRequest,
          deletedVersions: deletedVersions,
          serverNow: serverNow,
          deviceNow: deviceNow,
          complete: read.complete,
          // Same clock as the query: the server compared `changed_at` with
          // this exact [since], so no device/server mapping is involved.
          removableSince: since.add(policy.removalMargin),
        );
        // A completed match can leave the hot overlay table after its
        // canonical snapshot is stored. Forget the overlay, not its ordering
        // evidence: an older REST/socket replay is not a new incarnation.
        for (final entry in state.entries) {
          if (!reconciled.containsKey(entry.key)) {
            rememberRetiredTerminal(entry.value);
          }
        }
        state
          ..clear()
          ..addAll(reconciled);
        deletedVersions.removeWhere((id, _) => state.containsKey(id));
        // A failed or cut read is retried on the next tick, joined or not; a
        // read that hit maxPages is not (it would only repeat the same cut).
        lastBootstrap = read.complete || read.exhausted ? deviceNow : null;
        emit();
      } catch (_) {
        /* Keep HTTP snapshot and the last valid overlay. */
        lastBootstrap = null;
      } finally {
        if (identical(bootstrapToken, token)) bootstrapToken = null;
        if (identical(bootstrapDeletes, deletedDuringRequest)) {
          bootstrapDeletes = null;
        }
      }
    }

    Future<void> bootstrap() async {
      if (!_appActive) return;
      if (bootstrapping) {
        bootstrapAgain = true;
        return;
      }
      bootstrapping = true;
      try {
        do {
          bootstrapAgain = false;
          await bootstrapOnce();
        } while (bootstrapAgain && !disposed && _appActive);
      } finally {
        bootstrapping = false;
      }
    }

    late Future<void> Function() connect;
    void reconnect() {
      joined = false;
      heartbeat?.cancel();
      joinTimeout?.cancel();
      if (!_appActive || (scopedRealtime && realtimeMatchIds.isEmpty)) return;
      if (!disposed && !(retry?.isActive ?? false)) {
        retry = Timer(retryDelay, () {
          unawaited(connect());
        });
      }
    }

    connect = () async {
      if (disposed || connecting || !_appActive) return;
      final scopedIds = scopedRealtime ? realtimeMatchIds : const <String>[];
      if (scopedRealtime && scopedIds.isEmpty) return;
      final joiningScopeVersion = scopeVersion;
      connecting = true;
      try {
        final current = await WebSocket.connect(config.websocketUri.toString())
            .timeout(const Duration(seconds: 10));
        if (disposed || !_appActive || joiningScopeVersion != scopeVersion) {
          await current.close();
          if (!disposed) reconnect();
          return;
        }
        socket = current;
        final joinRef = '${++sequence}';
        current.add(
          jsonEncode({
            'topic': 'realtime:futbeat:live_match_updates',
            'event': 'phx_join',
            'payload': {
              'config': {
                'broadcast': {'ack': false, 'self': false},
                'presence': {'enabled': false, 'key': ''},
                'postgres_changes': [
                  {
                    'event': '*',
                    'schema': 'public',
                    'table': 'live_match_updates',
                    if (scopedRealtime)
                      'filter': 'match_id=in.(${scopedIds.join(',')})',
                  },
                ],
                'private': false,
              },
            },
            'ref': joinRef,
            'join_ref': joinRef,
          }),
        );
        joinTimeout = Timer(const Duration(seconds: 10), () {
          unawaited(current.close());
        });
        heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
          try {
            current.add(
              jsonEncode({
                'topic': 'phoenix',
                'event': 'heartbeat',
                'payload': {},
                'ref': '${++sequence}',
              }),
            );
          } catch (_) {
            unawaited(current.close());
          }
        });
        current.listen(
          (raw) {
            try {
              if (raw is! String ||
                  disposed ||
                  !_appActive ||
                  !identical(socket, current) ||
                  joiningScopeVersion != scopeVersion) {
                return;
              }
              final message = jsonDecode(raw) as Map;
              if (message['event'] == 'phx_reply' &&
                  message['ref'] == joinRef) {
                joinTimeout?.cancel();
                if (message['payload']?['status'] == 'ok') {
                  joined = true;
                  // Subscribe first, then refetch on EVERY reconnect to close the offline gap.
                  unawaited(bootstrap());
                } else {
                  unawaited(current.close());
                }
                return;
              }
              if (['phx_error', 'phx_close'].contains(message['event'])) {
                joined = false;
                unawaited(current.close());
                return;
              }
              if (message['event'] != 'postgres_changes') return;
              final data = message['payload']?['data'];
              if (data is! Map) return;
              final row = data['type'] == 'DELETE'
                  ? data['old_record']
                  : data['record'];
              final matchId = row is Map ? row['match_id'] : null;
              if (scopedRealtime &&
                  (matchId is! String ||
                      !scopedIds.contains(matchId) ||
                      !realtimeMatchIds.contains(matchId))) {
                return;
              }
              if (data['type'] == 'DELETE') {
                final previous = state[matchId];
                final deletedAt = row is Map && row['changed_at'] is String
                    ? DateTime.tryParse(row['changed_at'] as String)
                    : null;
                final deletedRevision = row is Map ? row['revision'] : null;
                final priorDeletion = deletedVersions[matchId];
                final priorDeletedAt = DateTime.tryParse(
                  priorDeletion?['changed_at'] as String? ?? '',
                );
                // FULL replica identity can carry an older deleted version
                // after a newer correction/reinsert has already arrived.
                // PK-only deletes have no ordering evidence and keep their
                // authoritative removal semantics.
                if ((priorDeletedAt != null &&
                        deletedAt != null &&
                        (deletedAt.isBefore(priorDeletedAt) ||
                            (deletedAt.isAtSameMomentAs(priorDeletedAt) &&
                                row is Map &&
                                row['provider'] == priorDeletion?['provider'] &&
                                deletedRevision is num &&
                                priorDeletion?['revision'] is num &&
                                deletedRevision <
                                    (priorDeletion!['revision'] as num)))) ||
                    (previous != null &&
                        ((deletedAt != null &&
                                deletedAt.isBefore(previous.changedAt)) ||
                            (row is Map &&
                                row['provider'] == previous.provider &&
                                deletedRevision is num &&
                                deletedRevision < previous.revision)))) {
                  emit();
                  return;
                }
                state.remove(matchId);
                if (matchId is String && deletedAt != null && row is Map) {
                  rememberVersionFence(matchId, {
                    'changed_at': row['changed_at'],
                    'provider': row['provider'],
                    'revision': row['revision'],
                  });
                } else {
                  // A PK-only removal must not discard terminal evidence we
                  // already observed for this match.
                  rememberRetiredTerminal(previous);
                }
                if (matchId is String) bootstrapDeletes?.add(matchId);
              } else if (data['record'] is Map) {
                accept(Map<String, dynamic>.from(data['record'] as Map));
                // A later valid INSERT/UPDATE supersedes this request's
                // deletion marker; normal revision checks protect it from
                // an older REST answer.
                if (matchId is String && state.containsKey(matchId)) {
                  bootstrapDeletes?.remove(matchId);
                }
              }
              emit();
            } catch (_) {
              /* Malformed frames do not erase valid data. */
            }
          },
          onDone: () {
            if (identical(socket, current)) reconnect();
          },
          onError: (_) {
            unawaited(current.close());
            if (identical(socket, current)) reconnect();
          },
        );
      } catch (_) {
        reconnect();
      } finally {
        connecting = false;
      }
    };
    controller = StreamController<Map<String, LiveMatchUpdate>>(
      onListen: () {
        if (!config.isConfigured || _scopeChanges.isClosed) {
          emit();
          unawaited(controller.close());
          return;
        }
        _closeWatches.add(closeWatch);
        refreshScope = () async {
          if (disposed ||
              !_appActive ||
              (scopedRealtime && realtimeMatchIds.isEmpty)) {
            return;
          }
          await bootstrap();
        };
        _refreshActiveScopes.add(refreshScope!);
        setScopeActive = (active) {
          scopeVersion++;
          bootstrapToken?.cancel('App backgrounded or resumed');
          retry?.cancel();
          retry = null;
          heartbeat?.cancel();
          joinTimeout?.cancel();
          scopeDebounce?.cancel();
          joined = false;
          final old = socket;
          socket = null;
          if (old != null) unawaited(old.close());
          if (active && !disposed) {
            unawaited(connect());
            unawaited(bootstrap());
          }
        };
        _setActiveScopes.add(setScopeActive!);
        if (!scopedRealtime || realtimeMatchIds.isNotEmpty) {
          unawaited(bootstrap());
        }
        unawaited(connect());
        if (scopedRealtime) {
          scopeSubscription = _scopeChanges.stream.listen((_) {
            scopeDebounce?.cancel();
            scopeDebounce = Timer(const Duration(milliseconds: 250), () {
              final ids = realtimeMatchIds.toSet();
              deletedVersions.removeWhere((id, _) => !ids.contains(id));
              scopeVersion++;
              bootstrapToken?.cancel('LIVE scope changed');
              joined = false;
              retry?.cancel();
              retry = null;
              heartbeat?.cancel();
              joinTimeout?.cancel();
              final old = socket;
              socket = null;
              if (old != null) unawaited(old.close());
              if (_appActive && realtimeMatchIds.isNotEmpty) {
                unawaited(bootstrap());
              }
              unawaited(connect());
            });
          });
        }
        refresh = Timer.periodic(refreshInterval, (_) {
          if (!_appActive) return;
          if (scopedRealtime && realtimeMatchIds.isEmpty) return;
          // Joined: realtime carries the changes, REST is only a safety net.
          final last = lastBootstrap;
          if (joined &&
              last != null &&
              DateTime.now().toUtc().difference(last) <
                  bootstrapPolicy.joinedRefreshInterval) {
            return;
          }
          unawaited(bootstrap());
        });
      },
      onCancel: stopWatch,
    );
    return controller.stream;
  }
}

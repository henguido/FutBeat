import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'models.dart';

/// [serverNow] is the REST response's server time (HTTP `Date`) and
/// [deviceNow] the device time it arrived; together they give every row a
/// skew-free receipt time (#120: an old LIVE row never looks fresh).
///
/// Absence only means "deleted on the server" when the answer is [complete]
/// (every page read). With [removableSince] (device time) the request covered
/// only rows updated since then: an overlay observed before it was simply not
/// asked for, so it is kept. A partial answer never removes anything.
Map<String, LiveMatchUpdate> reconcileLiveBootstrapSnapshot(
  Map<String, LiveMatchUpdate> current,
  Iterable<Json> rows, {
  Set<String>? keysBeforeRequest,
  DateTime? serverNow,
  DateTime? deviceNow,
  bool complete = true,
  DateTime? removableSince,
}) {
  final result = Map<String, LiveMatchUpdate>.of(current);
  final before = keysBeforeRequest ?? current.keys.toSet();
  final fetched = <String>{};
  final arrivedAt = (deviceNow ?? DateTime.now()).toUtc();

  for (final row in rows) {
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
      final previous = result[update.matchId];
      if (previous != null &&
          (update.changedAt.isBefore(previous.changedAt) ||
              (update.provider == previous.provider &&
                  update.revision < previous.revision))) {
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

  if (!complete) return result;
  result.removeWhere(
    (matchId, update) =>
        before.contains(matchId) &&
        !fetched.contains(matchId) &&
        (removableSince == null ||
            !(update.receivedAt ?? update.changedAt).toUtc().isBefore(
              removableSince.toUtc(),
            )),
  );
  return result;
}

/// How the REST bootstrap reads `live_match_updates`: only the rows updated
/// inside [window] (an older LIVE row is ignored by the overlay after
/// [LiveMatchUpdate.staleAfter]; an older terminal row is already in the
/// stored snapshots), in [pageSize] pages by primary key, far below the
/// PostgREST row cap (1000), so a short page reliably means "last page".
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

  /// Overlays this close to the window start are never removed (boundary,
  /// clock and paging races): only rows clearly inside the window are.
  final Duration removalMargin;

  /// While the realtime channel is joined, the periodic REST check runs at
  /// most this often (realtime carries the changes; REST is the safety net).
  final Duration joinedRefreshInterval;
}

/// The columns [LiveMatchUpdate.fromJson] and the receipt time read.
const liveBootstrapColumns =
    'match_id,provider,external_match_id,status,minute,home_score,away_score,'
    'revision,event_count,latest_events,changed_at,updated_at';

/// One bootstrap read: the rows, whether every page was read, and the server
/// time of the first answer (HTTP `Date`).
typedef LiveBootstrapRead = ({
  List<Json> rows,
  bool complete,
  DateTime? serverNow,
});

/// Reads the rows updated since [since] page by page (keyset on
/// `match_id`). A failure after some pages returns what was read as a
/// partial answer; a failure on the first page throws.
Future<LiveBootstrapRead> fetchLiveBootstrap(
  Dio dio,
  LiveRealtimeConfig config,
  LiveBootstrapPolicy policy, {
  required DateTime since,
}) async {
  final rows = <Json>[];
  DateTime? serverNow;
  String? after;
  LiveBootstrapRead partial() =>
      (rows: rows, complete: false, serverNow: serverNow);
  for (var page = 0; page < policy.maxPages; page++) {
    final Response<dynamic> response;
    try {
      response = await dio.getUri<dynamic>(
        config.bootstrapPageUri(
          since: since,
          after: after,
          limit: policy.pageSize,
        ),
        options: Options(headers: {'apikey': config.publicKey}),
      );
    } catch (_) {
      if (page == 0) rethrow;
      return partial();
    }
    if (serverNow == null) {
      try {
        final date = response.headers.value('date');
        if (date != null) serverNow = HttpDate.parse(date);
      } catch (_) {
        serverNow = null; // Conservative fallback: row timestamps.
      }
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
    if (data.length < policy.pageSize) {
      return (rows: rows, complete: true, serverNow: serverNow);
    }
    final last = pageRows.isEmpty ? null : pageRows.last['match_id'];
    if (last is! String || last == after) return partial();
    after = last;
  }
  return partial();
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

  /// One bootstrap page: rows updated since [since] (server time), ordered
  /// by primary key, after the keyset cursor [after].
  Uri bootstrapPageUri({
    required DateTime since,
    required int limit,
    String? after,
  }) => Uri.parse('$supabaseUrl/rest/v1/live_match_updates').replace(
    queryParameters: {
      'select': liveBootstrapColumns,
      'updated_at': 'gte.${since.toUtc().toIso8601String()}',
      if (after != null) 'match_id': 'gt.$after',
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
  });
  final LiveRealtimeConfig config;
  final Dio dio;
  final Duration retryDelay, refreshInterval;
  final LiveBootstrapPolicy bootstrapPolicy;

  Stream<Map<String, LiveMatchUpdate>> watch() {
    final state = <String, LiveMatchUpdate>{};
    late StreamController<Map<String, LiveMatchUpdate>> controller;
    WebSocket? socket;
    Timer? retry, heartbeat, refresh, joinTimeout;
    var disposed = false;
    var connecting = false;
    var sequence = 0;
    // One bootstrap at a time; a request during one runs once more after it
    // (e.g. the join right after the first read: closes the subscribe gap).
    var bootstrapping = false;
    var bootstrapAgain = false;
    var joined = false;
    DateTime? lastBootstrap;
    // Server minus device clock, from the last answer's `Date`.
    var serverOffset = Duration.zero;

    void emit() {
      if (!disposed) {
        controller.add(
          Map.unmodifiable(Map<String, LiveMatchUpdate>.of(state)),
        );
      }
    }

    void accept(Json row) {
      // A realtime frame is new now: its receipt time is local.
      final update = LiveMatchUpdate.fromJson(
        row,
        receivedAt: DateTime.now().toUtc(),
      );
      if (!update.matchId.startsWith('fb_')) return;
      final previous = state[update.matchId];
      if (previous != null &&
          (update.changedAt.isBefore(previous.changedAt) ||
              (update.provider == previous.provider &&
                  update.revision < previous.revision))) {
        return;
      }
      state[update.matchId] = update;
    }

    Future<void> bootstrapOnce() async {
      final before = state.keys.toSet();
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
        );
        if (disposed) return;
        final deviceNow = DateTime.now().toUtc();
        final serverNow = read.serverNow;
        if (serverNow != null) serverOffset = serverNow.difference(deviceNow);
        final reconciled = reconcileLiveBootstrapSnapshot(
          state,
          read.rows,
          keysBeforeRequest: before,
          serverNow: serverNow,
          deviceNow: deviceNow,
          // Without a server time the window cannot be placed on the device
          // clock: nothing is removed.
          complete: read.complete && serverNow != null,
          removableSince: serverNow == null
              ? null
              : deviceNow
                    .subtract(serverNow.difference(since))
                    .add(policy.removalMargin),
        );
        state
          ..clear()
          ..addAll(reconciled);
        // A partial read is retried on the next tick, joined or not.
        lastBootstrap = read.complete ? deviceNow : null;
        emit();
      } catch (_) {
        /* Keep HTTP snapshot and the last valid overlay. */
        lastBootstrap = null;
      }
    }

    Future<void> bootstrap() async {
      if (bootstrapping) {
        bootstrapAgain = true;
        return;
      }
      bootstrapping = true;
      try {
        do {
          bootstrapAgain = false;
          await bootstrapOnce();
        } while (bootstrapAgain && !disposed);
      } finally {
        bootstrapping = false;
      }
    }

    late Future<void> Function() connect;
    void reconnect() {
      joined = false;
      heartbeat?.cancel();
      joinTimeout?.cancel();
      if (!disposed && !(retry?.isActive ?? false)) {
        retry = Timer(retryDelay, () {
          unawaited(connect());
        });
      }
    }

    connect = () async {
      if (disposed || connecting) return;
      connecting = true;
      try {
        final current = await WebSocket.connect(config.websocketUri.toString())
            .timeout(const Duration(seconds: 10));
        if (disposed) {
          await current.close();
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
              if (raw is! String || disposed) return;
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
              if (data['type'] == 'DELETE') {
                state.remove(data['old_record']?['match_id']);
              } else if (data['record'] is Map) {
                accept(Map<String, dynamic>.from(data['record'] as Map));
              }
              emit();
            } catch (_) {
              /* Malformed frames do not erase valid data. */
            }
          },
          onDone: reconnect,
          onError: (_) {
            unawaited(current.close());
            reconnect();
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
        if (!config.isConfigured) {
          emit();
          unawaited(controller.close());
          return;
        }
        unawaited(bootstrap());
        unawaited(connect());
        refresh = Timer.periodic(refreshInterval, (_) {
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
      onCancel: () async {
        disposed = true;
        retry?.cancel();
        heartbeat?.cancel();
        refresh?.cancel();
        joinTimeout?.cancel();
        await socket?.close();
      },
    );
    return controller.stream;
  }
}

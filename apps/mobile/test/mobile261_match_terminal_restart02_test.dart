import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/live_realtime.dart';

import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/qa_diagnostics.dart';

// Synthetic canonical terminal observation. No real backend or provider calls.
const _id = 'fb_match_terminal_restart02';

class _FixtureClient extends LiveRealtimeClient {
  _FixtureClient(this.updates)
    : super(const LiveRealtimeConfig(supabaseUrl: '', publicKey: ''), Dio());
  final Stream<Map<String, LiveMatchUpdate>> updates;
  @override
  Stream<Map<String, LiveMatchUpdate>> watch() => updates;
}

class _FailFirstWrite extends AppDatabase {
  _FailFirstWrite(File file) : super(NativeDatabase(file));
  bool fail = true;
  @override
  Future<void> rewriteStoredSportingSnapshots(
    String? Function(String) rewrite,
  ) {
    if (fail) {
      fail = false;
      return Future.error(StateError('Synthetic local disk write failed'));
    }
    return super.rewriteStoredSportingSnapshots(rewrite);
  }
}

void main() {
  for (final mode in [
    'plain',
    'old-http',
    'disk-retry',
    'partial',
    'correction',
    'old-terminal',
    'unobserved-terminal',
  ]) {
    _verify(mode);
  }
}

void _verify(String mode) {
  test('S04 M03: terminal persists after file restart ($mode)', () async {
    final directory = await Directory.systemTemp.createTemp(
      'futbeat-terminal261-',
    );
    final file = File.fromUri(directory.uri.resolve('cache.sqlite'));
    AppDatabase db = mode == 'disk-retry'
        ? _FailFirstWrite(file)
        : AppDatabase(NativeDatabase(file));
    var dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
    final now = DateTime.now().toUtc();
    final raw = <String, dynamic>{
      'entityRedirects': {'fb_team_old_h': 'fb_team_h'},
      'schemaVersion': 1,
      'demo': false,
      'updatedAt': now.toIso8601String(),
      'teams': [
        {'id': 'fb_team_h', 'name': 'Local fixture'},
        {'id': 'fb_team_a', 'name': 'Visita fixture'},
        {'id': 'fb_team_unrelated', 'name': 'Local fixture'},
      ],
      'competitions': [
        {'id': 'fb_comp_c', 'name': 'Competición fixture'},
      ],
      'players': [
        {'id': 'fb_player_unrelated', 'name': 'Local fixture'},
      ],
      'standings': <Json>[],
      'matches': [
        {
          'id': _id,
          'homeTeamId': 'fb_team_h',
          'awayTeamId': 'fb_team_a',
          'competitionId': 'fb_comp_c',
          'startTime': now.subtract(const Duration(hours: 2)).toIso8601String(),
          'status': 'LIVE',
          'minute': 89,
          'score': {'home': 1, 'away': 0},
          'events': <Json>[],
        },
      ],
    };
    Json responseRaw = raw;
    var requests = 0;
    final oldRequest = Completer<void>();
    final releaseOld = Completer<void>();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) async {
          requests++;
          if (mode == 'old-http' && requests == 2 && !releaseOld.isCompleted) {
            oldRequest.complete();
            await releaseOld.future;
          }
          handler.resolve(Response(requestOptions: request, data: responseRaw));
        },
      ),
    );
    final metrics = QaDiagnostics();
    var repository = ApiRepository(
      dio,
      db,
      const CalendarCachePolicy(),
      null,
      metrics,
    );
    final base = await repository.loadMatchContext(_id);
    await repository.settleBackground();
    await db.saveCalendarSnapshot('2026-11-03', jsonEncode(raw));
    final detailPayload = jsonEncode({
      ...jsonDecode(
        File('test/fixtures/match_detail_object_lineup.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>,
      'matchId': _id,
    });
    await db.savePublicSnapshot('public:match-detail:$_id', detailPayload);
    final beforePublicRowId =
        (await db
                .customSelect(
                  "SELECT rowid AS rid FROM catalog_snapshots WHERE cache_key LIKE 'public:match-context:%'",
                )
                .get())
            .single
            .data['rid'];
    final beforeCalendarRowId =
        (await db
                .customSelect('SELECT rowid AS rid FROM calendar_snapshots')
                .get())
            .single
            .data['rid'];
    final beforePublic = (await db.readPublicSnapshot(
      'public:match-context:$_id',
    ))!.savedAt;
    final beforeCalendar = (await db.readCalendarEntry('2026-11-03'))!.savedAt;
    final Future<Snapshot>? held = mode == 'old-http'
        ? repository.loadMatchContext(_id)
        : null;
    if (held != null) await oldRequest.future;
    final updates = StreamController<Map<String, LiveMatchUpdate>>();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        repositoryProvider.overrideWithValue(repository),
        snapshotProvider.overrideWith((ref) async => base),
        demoModeProvider.overrideWithValue(false),
        liveRealtimeClientProvider.overrideWithValue(
          _FixtureClient(updates.stream),
        ),
      ],
    );
    final observed = Completer<void>();
    final subscription = container.listen(effectiveSnapshotProvider, (
      _,
      value,
    ) {
      if (value.asData?.value.match(_id)?.status == 'VERIFIED' &&
          !observed.isCompleted) {
        observed.complete();
      }
    }, fireImmediately: true);
    try {
      await container.read(snapshotProvider.future);
      updates.add({
        _id: LiveMatchUpdate.fromJson({
          'match_id': _id,
          'provider': 'fixture',
          'external_match_id': 'fixture_terminal',
          'status': 'VERIFIED',
          'minute': 90,
          'home_score': 2,
          'away_score': 0,
          'revision': 2,
          'event_count': 0,
          'changed_at': now.toIso8601String(),
          'provider_observed_at': now.toIso8601String(),
          'latest_events': <Json>[],
        }, receivedAt: now),
      });
      await observed.future.timeout(const Duration(seconds: 3));
      final shown = container
          .read(effectiveSnapshotProvider)
          .asData!
          .value
          .match(_id)!;
      expect(shown.status, 'VERIFIED');
      expect(shown.json['score']['home'], 2);
      await repository.settleBackground();
      expect(
        requests,
        mode == 'old-http' ? 2 : 1,
        reason: 'Observing a final must not issue another GET',
      );
      expect(
        (await db.readPublicSnapshot('public:match-context:$_id'))!.savedAt,
        beforePublic,
      );
      expect(
        (await db.readCalendarEntry('2026-11-03'))!.savedAt,
        beforeCalendar,
      );
      expect(
        (await db
                .customSelect(
                  "SELECT rowid AS rid FROM catalog_snapshots WHERE cache_key LIKE 'public:match-context:%'",
                )
                .get())
            .single
            .data['rid'],
        beforePublicRowId,
      );
      expect(
        (await db
                .customSelect('SELECT rowid AS rid FROM calendar_snapshots')
                .get())
            .single
            .data['rid'],
        beforeCalendarRowId,
      );
      if (mode == 'disk-retry') {
        expect(
          (metrics.snapshot()['counts']
              as Map)['/local/terminal:sqliteWriteError'],
          1,
        );
        expect(
          (jsonDecode(
            (await db.readPublicSnapshot('public:match-context:$_id'))!.payload,
          ) as Map)['matches'].single['status'],
          'LIVE',
        );
        repository.setAppActive(false);
        repository.setAppActive(true);
        await repository.settleBackground();
        expect(
          (metrics.snapshot()['counts'] as Map)['/local/terminal:sqliteWrite'],
          1,
        );
      }
      if (held != null) {
        releaseOld.complete();
        await held;
        await repository.settleBackground();
      }
      if ([
        'partial',
        'correction',
        'old-terminal',
        'unobserved-terminal',
      ].contains(mode)) {
        responseRaw = {
          ...raw,
          'updatedAt': now.add(const Duration(minutes: 1)).toIso8601String(),
          'matches': mode == 'partial'
              ? <Json>[]
              : [
                  for (final row in raw['matches'] as List)
                    {
                      ...Map<String, dynamic>.from(row as Map),
                      'status': 'VERIFIED',
                      'score': {
                        'home': mode == 'old-terminal' ? 1 : 3,
                        'away': 0,
                      },
                      if (mode != 'unobserved-terminal') ...{
                        'liveProvider': 'fixture',
                        'liveRevision': mode == 'old-terminal' ? 1 : 3,
                        'liveChangedAt':
                            (mode == 'old-terminal'
                                    ? now.subtract(const Duration(minutes: 1))
                                    : now.add(const Duration(seconds: 20)))
                                .toIso8601String(),
                        'liveObservedAt':
                            (mode == 'old-terminal'
                                    ? now.subtract(const Duration(minutes: 1))
                                    : now.add(const Duration(seconds: 20)))
                                .toIso8601String(),
                      },
                    },
                ],
        };
        if (mode == 'partial') {
          responseRaw['teams'] = <Json>[];
          responseRaw['players'] = <Json>[];
          responseRaw['competitions'] = <Json>[];
          responseRaw['entityRedirects'] = {
            'fb_team_old_h': 'fb_team_replacement',
          };
        }
        final corrected = await repository.loadMatchContext(_id);
        if (mode == 'correction') {
          expect(corrected.match(_id)!.json['score']['home'], 3);
        }
        if (mode == 'partial') {
          expect(corrected.match(_id)!.status, 'VERIFIED');
          expect(corrected.stale, isTrue);
        }
        await repository.settleBackground();
      }
      subscription.close();
      container.dispose();
      await updates.close();
      await db.close();
      dio.close(force: true);
      db = AppDatabase(NativeDatabase(file));
      dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) async {
            requests++;
            if (mode == 'old-http' &&
                requests == 2 &&
                !releaseOld.isCompleted) {
              oldRequest.complete();
              await releaseOld.future;
            }
            handler.reject(
              DioException(
                requestOptions: request,
                error: 'Offline restart must not request HTTP',
              ),
            );
          },
        ),
      );
      repository = ApiRepository(dio, db);
      final reopened = await repository.watchPublicMatchContext(_id).first;
      expect(
        reopened.stale,
        isTrue,
        reason: 'A stored final must still be labelled offline/stale',
      );
      expect(
        requests,
        [
              'old-http',
              'partial',
              'correction',
              'old-terminal',
              'unobserved-terminal',
            ].contains(mode)
            ? 2
            : 1,
      );
      expect(
        reopened.match(_id)!.status,
        'VERIFIED',
        reason: 'A previously observed final must not return as cached LIVE',
      );
      expect(
        reopened.resolveEntityId('fb_team_old_h'),
        mode == 'partial' ? 'fb_team_replacement' : 'fb_team_h',
      );
      if (mode == 'partial') {
        expect(reopened.team('fb_team_unrelated'), isNull);
        expect(reopened.player('fb_player_unrelated'), isNull);
      }
      expect(
        (await db.readPublicSnapshot('public:match-detail:$_id'))!.payload,
        detailPayload,
      );
      expect(
        reopened.match(_id)!.json['score']['home'],
        mode == 'correction' ? 3 : 2,
      );
    } finally {
      if (!releaseOld.isCompleted) releaseOld.complete();
      subscription.close();
      container.dispose();
      if (!updates.isClosed) await updates.close();
      dio.close(force: true);
      await db.close();
      final path = await directory.resolveSymbolicLinks();
      final root = await Directory.systemTemp.resolveSymbolicLinks();
      if (!path.startsWith(root + Platform.pathSeparator)) {
        throw StateError('Unexpected fixture path');
      }
      await directory.delete(recursive: true);
    }
  });
}

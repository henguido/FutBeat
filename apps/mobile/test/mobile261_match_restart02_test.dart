import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/entity_media.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/match_screen.dart';

// Local contract acceptance, NOT real provider/Android/photograph validation.
// Reuses the existing synthetic object-lineup fixture. HTTPS URLs are metadata;
// the test never downloads pictures or opens a sports/provider endpoint.
class _BlockedWire implements HttpClientAdapter {
  int attempts = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    attempts++;
    throw StateError('Transport forbidden in local restart test');
  }

  @override
  void close({bool force = false}) {}
}

const _id = 'fb_match_e2e';
Json _detail() => jsonDecode(
  File('test/fixtures/match_detail_object_lineup.json').readAsStringSync(),
) as Json;
Json _context(Json detail) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-11-03T00:00:00Z',
  'teams': [
    {'id': 'fb_team_restart_h', 'name': 'Local de fixture'},
    {'id': 'fb_team_restart_a', 'name': 'Visita de fixture'},
  ],
  'competitions': [
    {'id': 'fb_comp_restart', 'name': 'Competición de fixture'},
  ],
  'players': [
    for (final side in ['home', 'away'])
      for (final row in (detail[side] as Map)['starters'] as List)
        {
          'id': row['canonicalId'],
          'name': row['name'],
          if (row['image'] != null)
            'media': {'url': row['image'], 'verificationStatus': 'VERIFIED'},
        },
  ],
  'matches': [
    {
      'id': _id,
      'competitionId': 'fb_comp_restart',
      'homeTeamId': 'fb_team_restart_h',
      'awayTeamId': 'fb_team_restart_a',
      'startTime': '2026-10-29T18:00:00Z',
      'status': 'FINISHED',
      'score': {'home': 1, 'away': 0},
      'events': [
        {
          'id': 'fb_event_restart_goal',
          'providerEventId': 'fixture_goal_10',
          'type': 'GOAL',
          'minute': 10,
          'side': 'home',
          'playerId': 'fb_player_fixture_e2e_h1',
          'label': 'Gol de fixture',
        },
      ],
    },
  ],
  'standings': <Json>[],
};

Future<void> _pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(done(), isTrue);
}

void main() {
  testWidgets(
    'M03 M04 M06 M07: file restart keeps canonical detail and renders tabs with blocked transport',
    (tester) async {
      tester.view.physicalSize = const Size(420, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('futbeat-match261-'),
      ))!;
      final file = File.fromUri(directory.uri.resolve('cache.sqlite'));
      var db = AppDatabase(NativeDatabase(file));
      var dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
      ProviderContainer? container;
      var closed = false;
      addTearDown(() async {
        if (!closed) {
          await tester.pumpWidget(const SizedBox());
          container?.dispose();
          dio.close(force: true);
          await tester.pump(const Duration(seconds: 1));
          await tester.runAsync(db.close);
        }
        await tester.runAsync(() async {
          final path = await directory.resolveSymbolicLinks();
          final root = await Directory.systemTemp.resolveSymbolicLinks();
          if (!path.startsWith(root + Platform.pathSeparator)) {
            throw StateError('Unexpected fixture path');
          }
          await directory.delete(recursive: true);
        });
      });
      final raw = _detail();
      raw['incidents'] = [
        for (final event
            in (_context(raw)['matches'] as List).single['events'] as List)
          Map<String, dynamic>.from(event as Map),
      ];
      final context = _context(raw);
      final requests = <String>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request.path);
            handler.resolve(
              Response(
                requestOptions: request,
                data: request.path.endsWith('match-detail') ? raw : context,
              ),
            );
          },
        ),
      );
      final media = EntityMediaMemory();
      final online = (await tester.runAsync(
        () async => ApiRepository(dio, db, const CalendarCachePolicy(), media),
      ))!;
      await tester.runAsync(() async {
        await online.loadMatchContext(_id);
        await online.loadMatchDetail(_id);
        await online.settleBackground();
      });
      expect(requests, ['/v1/match-context', '/v1/match-detail']);
      await tester.runAsync(db.close);
      dio.close(force: true);
      // New connection, repository and media memory: no in-memory sporting state.
      db = AppDatabase(NativeDatabase(file));
      dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
      final blocked = <String>[];
      final wire = _BlockedWire();
      dio.httpClientAdapter = wire;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            blocked.add(request.path);
            handler.reject(
              DioException(
                requestOptions: request,
                type: DioExceptionType.connectionError,
                error: 'Offline fixture transport blocked',
              ),
            );
          },
        ),
      );
      final reopenedMedia = EntityMediaMemory();
      final offline = (await tester.runAsync(
        () async =>
            ApiRepository(dio, db, const CalendarCachePolicy(), reopenedMedia),
      ))!;
      offline.setAppActive(false);
      final storedContext = (await tester.runAsync(
        () => offline.watchPublicMatchContext(_id).first,
      ))!;
      final storedDetail = (await tester.runAsync(
        () => offline.readStoredMatchDetail(_id),
      ))!;
      expect(
        blocked,
        isEmpty,
        reason: 'SQLite reads themselves do not make HTTP requests',
      );
      expect(storedDetail.homeStarters, MatchDetail(raw).homeStarters);
      expect(storedDetail.homeSubstitutes, MatchDetail(raw).homeSubstitutes);
      expect(storedDetail.statistics, MatchDetail(raw).statistics);
      expect(
        storedContext.match(_id)!.events.single['id'],
        'fb_event_restart_goal',
      );
      expect(storedDetail.offlineStale, isTrue);
      expect(storedDetail.incidents.single['id'], 'fb_event_restart_goal');
      expect(
        mergedMatchTimeline(storedContext.match(_id)!, storedDetail),
        hasLength(1),
      );
      expect(
        reopenedMedia.imageFor('fb_player_fixture_e2e_h1'),
        'https://media.goal-api.com/players/h1.png',
      );
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          repositoryProvider.overrideWithValue(offline),
          entityMediaProvider.overrideWithValue(reopenedMedia),
          followsProvider.overrideWith((ref) => Stream.value({})),
          liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
          liveRealtimeConfigProvider.overrideWithValue(
            const LiveRealtimeConfig(supabaseUrl: '', publicKey: ''),
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: MatchScreen(id: _id, initialData: storedContext),
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () =>
            container!.read(matchDetailProvider(_id)).asData?.value.available ==
            true,
      );
      Future<void> tab(String key) async {
        final finder = find.byKey(ValueKey(key));
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await tester.pump(const Duration(milliseconds: 350));
      }

      await tab('match-tab-live');
      await _pumpUntil(
        tester,
        () => find
            .byWidgetPredicate(
              (widget) =>
                  widget.key is ValueKey<String> &&
                  (widget.key as ValueKey<String>).value.startsWith(
                    'timeline-event-fb_event_restart_goal-',
                  ),
            )
            .evaluate()
            .isNotEmpty,
      );
      await tab('match-tab-lineup');
      await _pumpUntil(
        tester,
        () => find.text('Defensa Sin Foto').evaluate().isNotEmpty,
      );
      expect(find.text('Portero Con Foto'), findsWidgets);
      expect(find.text('Defensa Sin Foto'), findsWidgets);
      await tab('match-tab-statistics');
      await _pumpUntil(tester, () => find.text('55%').evaluate().isNotEmpty);
      expect(find.text('55%'), findsWidgets);
      expect(find.text('45%'), findsWidgets);
      final revalidationCount = blocked.length;
      for (var second = 0; second < 25; second++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(seconds: 1));
      }
      expect(
        blocked.length,
        revalidationCount,
        reason: 'An offline detail error must not start a sports polling loop',
      );
      // Production providers may try bounded revalidation after the stored emission.
      // Those attempts are blocked before any transport; do not claim zero attempts.
      expect(blocked.every((path) => path.startsWith('/v1/')), isTrue);
      debugPrint(
        'MATCH261_LOCAL restart=1 canonicalTimeline=1 starters=3 substitutes=1 statistics=2 metadataPhotos=3 blockedRevalidations=${blocked.length} externalHTTP=0',
      );
      expect(
        wire.attempts,
        0,
        reason: 'No request may reach the HTTP transport',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      dio.close(force: true);
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() async {
        await offline.settleBackground();
        await db.close();
      });
      closed = true;
    },
  );
}

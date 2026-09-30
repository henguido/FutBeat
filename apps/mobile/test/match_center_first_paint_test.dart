import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/match_preview_sections.dart';
import 'package:futbeat/features/matches/match_screen.dart';

// First paint of a historical Match Center: what the calling screen already
// knows (teams, score, status, competition, date) is shown at once; the
// network only adds to it. Synthetic data, no real provider.

const _match = 'fb_match_fp';
const _home = 'fb_team_fp_home';
const _away = 'fb_team_fp_away';
const _competition = 'fb_comp_fp';

final _kickoff = DateTime.now().toUtc().subtract(const Duration(days: 40));

Json _meeting({Object? status = 'VERIFIED', Object? score}) => {
  'matchId': _match,
  'competitionId': _competition,
  'startTime': _kickoff.toIso8601String(),
  'status': status,
  'homeTeamId': _home,
  'awayTeamId': _away,
  'score': score ?? {'home': 3, 'away': 2},
  'result': 'WIN',
};

final _homeTeam = Entity({'id': _home, 'name': 'Local Histórico'});
final _awayTeam = Entity({'id': _away, 'name': 'Visita Histórica'});

Map<String, dynamic> _fullContext() => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': DateTime.now().toUtc().toIso8601String(),
  'coverage': {'partial': false},
  'freshness': {'stale': false},
  'competitions': [
    {'id': _competition, 'name': 'Liga Histórica', 'country': 'Costa Rica'},
  ],
  'teams': [_homeTeam.json, _awayTeam.json],
  'players': <dynamic>[],
  'matches': [
    {
      'id': _match,
      'competitionId': _competition,
      'homeTeamId': _home,
      'awayTeamId': _away,
      'startTime': _kickoff.toIso8601String(),
      'status': 'VERIFIED',
      'score': {'home': 3, 'away': 2},
      'events': <dynamic>[],
      'statistics': <dynamic>[],
    },
  ],
  'standings': <dynamic>[],
};

/// A server whose match context only answers when [gate] completes.
class _SlowServer {
  final gate = Completer<void>();
  int contextReads = 0;

  Dio dio() => Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/v1/match-context') {
            contextReads++;
            gate.future.then(
              (_) => handler.resolve(
                Response(requestOptions: options, data: _fullContext()),
              ),
            );
            return;
          }
          if (options.path == '/v1/match-preview') {
            handler.resolve(
              Response(
                requestOptions: options,
                data: {'schemaVersion': 1, 'matchId': _match},
              ),
            );
            return;
          }
          handler.resolve(
            Response(
              requestOptions: options,
              data: MatchDetail.empty(_match).json,
            ),
          );
        },
      ),
    );
}

Future<ProviderContainer> _open(
  WidgetTester tester,
  _SlowServer server, {
  Snapshot? initialData,
}) async {
  tester.view.physicalSize = const Size(390, 820);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final db = AppDatabase(NativeDatabase.memory());
  await tester.runAsync(() => db.customSelect('select 1').get());
  addTearDown(() => tester.runAsync(db.close));
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(ApiRepository(server.dio())),
      followsProvider.overrideWith((ref) => Stream.value({})),
      liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: MatchScreen(id: _match, initialData: initialData),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return container;
}

Future<void> _close(
  WidgetTester tester,
  ProviderContainer container,
  _SlowServer server,
) async {
  if (!server.gate.isCompleted) server.gate.complete();
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpWidget(const SizedBox());
  container.dispose();
}

void main() {
  test('meetingContext: a usable minimal context from a meeting row', () {
    final data = meetingContext(
      _meeting(),
      _homeTeam,
      _awayTeam,
      'Liga Histórica',
    )!;
    final match = data.match(_match)!;
    expect(match.status, 'VERIFIED');
    expect(match.score, '3 - 2');
    expect(match.statusLabel, 'Finalizado');
    expect(data.team(match.homeId)!.name, 'Local Histórico');
    expect(data.team(match.awayId)!.name, 'Visita Histórica');
    expect(data.competition(match.competitionId)!.name, 'Liga Histórica');
    expect(match.json['startTime'], _kickoff.toIso8601String());
    // An incomplete score is never invented.
    final noScore = meetingContext(
      _meeting(score: {'home': 1, 'away': null}),
      _homeTeam,
      _awayTeam,
      'Liga Histórica',
    )!;
    expect(noScore.match(_match)!.json['score'], isNull);
  });

  test('meetingContext: anything essential missing => null (normal load)', () {
    expect(meetingContext(_meeting(), null, _awayTeam, 'Liga'), isNull);
    expect(meetingContext(_meeting(), _homeTeam, null, 'Liga'), isNull);
    expect(meetingContext(_meeting(), _homeTeam, _awayTeam, null), isNull);
    expect(meetingContext(_meeting(), _homeTeam, _awayTeam, ''), isNull);
    expect(
      meetingContext(_meeting(status: null), _homeTeam, _awayTeam, 'Liga'),
      isNull,
    );
    expect(
      meetingContext(
        {..._meeting(), 'startTime': 'not-a-date'},
        _homeTeam,
        _awayTeam,
        'Liga',
      ),
      isNull,
    );
    expect(
      meetingContext(
        {..._meeting()}..remove('matchId'),
        _homeTeam,
        _awayTeam,
        'Liga',
      ),
      isNull,
    );
  });

  testWidgets('without initial data the screen waits for the network '
      '(baseline)', (tester) async {
    final server = _SlowServer();
    final container = await _open(tester, server);
    // Full-screen loader: no tabs, no teams.
    expect(find.byType(TabBar), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Local Histórico'), findsNothing);
    await _close(tester, container, server);
  });

  testWidgets('with the row data the header paints at once while the context '
      'is still loading, then the full context takes over', (tester) async {
    final server = _SlowServer();
    final container = await _open(
      tester,
      server,
      initialData: meetingContext(
        _meeting(),
        _homeTeam,
        _awayTeam,
        'Liga Histórica',
      ),
    );
    // The network has not answered yet.
    expect(server.gate.isCompleted, isFalse);
    expect(server.contextReads, 1, reason: 'the full context is still read');
    // First paint from known data: no full-screen loader.
    expect(find.byType(TabBar), findsOneWidget);
    expect(find.text('Local Histórico'), findsWidgets);
    expect(find.text('Visita Histórica'), findsWidgets);
    expect(find.textContaining('3'), findsWidgets);
    expect(tester.takeException(), isNull);

    // The network answers: same match, full context, no error flash.
    server.gate.complete();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Local Histórico'), findsWidgets);
    expect(find.text('No pudimos cargar este partido'), findsNothing);
    expect(server.contextReads, 1);
    expect(tester.takeException(), isNull);
    await _close(tester, container, server);
  });
}

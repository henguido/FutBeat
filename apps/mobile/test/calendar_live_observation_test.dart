import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';

const granada = 'fb_match_8da4aa4fd93b40c3b1ec9245ae28e05f';
const latvia = 'fb_match_2e973e3d22934415877893b868d89851';
final now = DateTime.utc(2026, 11, 15, 16, 45, 58);

Json match(
  String id,
  int minute, {
  String status = 'LIVE',
  DateTime? seen,
  DateTime? changed,
  int? revision,
  int? home,
}) => {
  'id': id,
  'startTime': now.subtract(const Duration(hours: 3)).toIso8601String(),
  'competitionId': 'fb_comp_fixture',
  'homeTeamId': 'fb_team_home',
  'awayTeamId': 'fb_team_away',
  'status': status,
  'minute': minute,
  'score': {'home': home ?? (id == granada ? 1 : 0), 'away': 0},
  if (changed != null) 'liveChangedAt': changed.toIso8601String(),
  if (revision != null) 'liveProvider': 'goal_api',
  'liveRevision': ?revision,
  if (seen != null)
    'provenance': {'providerObservedAt': seen.toIso8601String()},
};

void main() {
  final old = DateTime.utc(2026, 11, 15, 15, 50, 4);
  final recent = now.subtract(const Duration(seconds: 60));

  test('Granada at 70: a provider observation wins over an old change', () {
    final observed = FootballMatch(
      match(granada, 70, seen: recent, changed: old),
    );
    expect(observed.providerObservedAt, recent);
    expect(observed.liveDataStaleAt(now), isFalse);
    final unknown = FootballMatch(match(granada, 70, changed: old));
    expect(unknown.providerObservedAt, isNull);
    expect(unknown.liveDataStaleAt(now), isFalse);
  });

  test('Latvia at 90: old evidence warns and cannot manufacture a final', () {
    final stale = FootballMatch(match(latvia, 90, seen: old, changed: old));
    expect(stale.liveDataStaleAt(now), isTrue);
    expect(stale.isLive, isTrue);
    expect(stale.isFinished, isFalse);
    final terminal = FootballMatch(
      match(latvia, 90, status: 'VERIFIED', seen: old),
    );
    expect(terminal.isFinished, isTrue);
    expect(terminal.liveDataStaleAt(now), isFalse);
  });

  for (final terminalStatus in ['FINISHED', 'VERIFIED']) {
    test(
      'HTTP, SQLite replay, reconnect and delayed LIVE after $terminalStatus',
      () async {
        final database = AppDatabase(NativeDatabase.memory());
        final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
        addTearDown(database.close);
        addTearDown(() => dio.close(force: true));
        final date = DateTime.utc(2026, 11, 15);
        var envelope = now;
        var online = true;
        var rows = [
          match(granada, 59, seen: old),
          match(latvia, 90, seen: old),
        ];
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              if (!online) {
                return handler.reject(
                  DioException.connectionError(
                    requestOptions: request,
                    reason: 'offline',
                  ),
                );
              }
              handler.resolve(
                Response(
                  requestOptions: request,
                  data: {
                    'schemaVersion': 1,
                    'demo': false,
                    'updatedAt': envelope.toIso8601String(),
                    'matches': rows,
                    'teams': [
                      {'id': 'fb_team_home', 'name': 'Local'},
                      {'id': 'fb_team_away', 'name': 'Visita'},
                    ],
                    'competitions': [
                      {'id': 'fb_comp_fixture', 'name': 'Competición'},
                    ],
                    'players': [],
                    'standings': [],
                  },
                ),
              );
            },
          ),
        );
        ApiRepository repo = ApiRepository(dio, database);
        await repo.loadDate(date);
        await repo.settleBackground();

        rows = [match(granada, 65, seen: recent), match(latvia, 90, seen: old)];
        var read = await repo.loadDate(date);
        expect(read.match(granada)!.json['minute'], 65);
        expect(read.match(granada)!.liveDataStaleAt(now), isFalse);
        await repo.settleBackground();

        rows = [
          match(granada, 70),
          match(
            latvia,
            90,
            status: terminalStatus,
            changed: now,
            revision: 17,
            home: 1,
          ),
        ];
        read = await repo.loadDate(date);
        expect(read.match(granada)!.json['minute'], 70);
        expect(read.match(granada)!.providerObservedAt, recent);
        expect(read.match(latvia)!.score, '1 - 0');
        await repo.settleBackground();

        repo = ApiRepository(dio, database);
        online = false;
        repo.refreshDate(date);
        final offline = await repo
            .watchDate(date, retryDelay: Duration.zero)
            .toList();
        final cached = offline.last;
        expect(cached.stale, isTrue);
        expect(cached.match(granada)!.providerObservedAt, recent);
        expect(
          cached
              .match(granada)!
              .liveDataStaleAt(now.add(const Duration(hours: 1))),
          isTrue,
        );
        expect(cached.match(latvia)!.status, terminalStatus);

        online = true;
        envelope = now.add(const Duration(minutes: 1));
        rows = [match(granada, 70, seen: old), match(latvia, 90, seen: old)];
        // No prior cache read in this repository. The first HTTP response after
        // restart still needs the persisted correction and observation.
        repo = ApiRepository(dio, database);
        read = await repo.loadDate(date);
        expect(read.match(granada)!.providerObservedAt, recent);
        expect(read.match(latvia)!.status, terminalStatus);
        expect(read.match(latvia)!.score, '1 - 0');
        await repo.settleBackground();

        rows = [
          match(granada, 70),
          match(
            latvia,
            90,
            status: 'VERIFIED',
            changed: old,
            revision: 16,
            home: 0,
          ),
        ];
        read = await repo.loadDate(date);
        expect(read.match(latvia)!.score, '1 - 0');
        expect(read.match(latvia)!.json['liveRevision'], 17);
        await repo.settleBackground();

        rows = [
          match(granada, 70),
          match(
            latvia,
            90,
            status: 'VERIFIED',
            changed: envelope,
            revision: 18,
            home: 0,
          ),
        ];
        read = await repo.loadDate(date);
        expect(read.match(latvia)!.score, '0 - 0');
        expect(read.match(latvia)!.json['liveRevision'], 18);
        await repo.settleBackground();
      },
    );
  }
}

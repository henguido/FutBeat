import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/entity_media.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';

const requested = 'fb_match_context260';
const foreign = 'fb_match_foreign260';
const player = 'fb_player_context260';
const alias = 'fb_team_context_alias260';
const photo = 'https://media.example.test/foreign260.png';
Json context(String? id, String updatedAt, {bool foreignMedia = false}) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': updatedAt,
  'teams': [
    {'id': 'fb_team_home260', 'name': 'Local'},
    {'id': 'fb_team_away260', 'name': 'Visita'},
  ],
  'competitions': [
    {'id': 'fb_comp_context260', 'name': 'Liga controlada'},
  ],
  'players': foreignMedia
      ? [
          {
            'id': player,
            'name': 'Persona sintética',
            'media': {'url': photo, 'verificationStatus': 'VERIFIED'},
          },
        ]
      : <Json>[],
  if (foreignMedia) 'entityRedirects': {alias: 'fb_team_foreign260'},
  'standings': <Json>[],
  'matches': id == null
      ? <Json>[]
      : [
          {
            'id': id,
            'competitionId': 'fb_comp_context260',
            'homeTeamId': 'fb_team_home260',
            'awayTeamId': 'fb_team_away260',
            'startTime': '2026-10-01T20:00:00Z',
            'status': 'FINISHED',
            'score': {'home': 1, 'away': 0},
            'events': <Json>[],
            'statistics': <Json>[],
          },
        ],
};
void main() {
  test(
    'foreign match context cannot poison requested cache or shared media',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final media = EntityMediaMemory();
      final dio = Dio();
      var calls = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (r, h) => h.resolve(
            Response(
              requestOptions: r,
              data: ++calls == 1
                  ? context(foreign, '2026-11-03T23:00:00Z', foreignMedia: true)
                  : context(requested, '2026-11-03T20:00:00Z'),
            ),
          ),
        ),
      );
      final repository = ApiRepository(
        dio,
        db,
        const CalendarCachePolicy(),
        media,
      );
      addTearDown(() async {
        await repository.settleBackground();
        dio.close(force: true);
        media.dispose();
        await db.close();
      });
      await expectLater(
        repository.loadMatchContext(requested),
        throwsA(isA<FormatException>()),
      );
      expect(media.imageFor(player), isNull);
      expect(media.redirects.resolve(alias), alias);
      expect(
        await db.readPublicSnapshot('public:match-context:$requested'),
        isNull,
      );
      final accepted = await repository.loadMatchContext(requested);
      expect(accepted.match(requested), isNotNull);
      expect(accepted.match(foreign), isNull);
      await repository.settleBackground();
      final stored = await db.readPublicSnapshot(
        'public:match-context:$requested',
      );
      expect(
        Snapshot(jsonDecode(stored!.payload) as Json).match(requested),
        isNotNull,
      );
      expect(calls, 2);
    },
  );
  test('foreign context preserves last good requested context without accepting foreign timestamp', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final dio = Dio();
    var calls = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (r, h) => h.resolve(
          Response(
            requestOptions: r,
            data: ++calls == 2
                ? context(foreign, '2026-11-03T23:00:00Z')
                : context(
                    requested,
                    calls == 1
                        ? '2026-11-03T20:00:00Z'
                        : '2026-11-03T21:00:00Z',
                  ),
          ),
        ),
      ),
    );
    final repository = ApiRepository(dio, db);
    addTearDown(() async {
      await repository.settleBackground();
      dio.close(force: true);
      await db.close();
    });
    await repository.loadMatchContext(requested);
    final preserved = await repository.loadMatchContext(requested);
    expect(preserved.match(requested), isNotNull);
    expect(preserved.match(foreign), isNull);
    final newer = await repository.loadMatchContext(requested);
    expect(newer.updatedAt, DateTime.parse('2026-11-03T21:00:00Z'));
    expect(newer.match(requested), isNotNull);
  });
  test('empty context remains a legitimate no-data response', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (r, h) => h.resolve(
          Response(
            requestOptions: r,
            data: context(null, '2026-11-03T20:00:00Z'),
          ),
        ),
      ),
    );
    addTearDown(() => dio.close(force: true));
    expect(
      (await ApiRepository(dio).loadMatchContext(requested)).matches,
      isEmpty,
    );
  });
}

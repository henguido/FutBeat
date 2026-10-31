import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/entity_media.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';

const _player = 'fb_player_cache245';
const _team = 'fb_team_cache245';
const _match = 'fb_match_cache245';
const _alias = 'fb_player_alias245';
const _newTarget = 'fb_player_canonical245';
const _oldTarget = 'fb_player_retired245';
const _newImage = 'https://media.example.test/current245.png';
const _oldImage = 'https://media.example.test/older245.png';

Json _payload({required bool current}) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': current ? '2026-10-31T22:00:00Z' : '2026-10-30T22:00:00Z',
  'entityRedirects': {_alias: current ? _newTarget : _oldTarget},
  'teams': [
    {'id': _team, 'name': 'Local sintético'},
    {'id': 'fb_team_away245', 'name': 'Visitante sintético'},
  ],
  'players': [
    {
      'id': _player,
      'name': 'Persona sintética',
      'media': {
        'verificationStatus': 'VERIFIED',
        'url': current ? _newImage : _oldImage,
      },
    },
    {'id': _newTarget, 'name': 'Identidad canónica sintética'},
    {'id': _oldTarget, 'name': 'Identidad anterior sintética'},
  ],
  'competitions': [
    {'id': 'fb_comp_cache245', 'name': 'Competición sintética'},
  ],
  'matches': [
    {
      'id': _match,
      'competitionId': 'fb_comp_cache245',
      'homeTeamId': _team,
      'awayTeamId': 'fb_team_away245',
      'startTime': '2026-10-31T18:00:00Z',
      'status': 'VERIFIED',
      'score': {'home': 1, 'away': 0},
    },
  ],
  'standings': <Json>[],
};

void main() {
  for (final available in [true, false]) {
    test('rejected cached detail cannot publish media (available=$available)', () async {
      final database = AppDatabase(NativeDatabase.memory());
      final media = EntityMediaMemory()
        ..absorb(Snapshot(_payload(current: true)));
      final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
      final repository = ApiRepository(
        dio,
        database,
        const CalendarCachePolicy(),
        media,
      );
      try {
        // Simulate a corrupt/obsolete local entry, not an API response.
        // A valid store never deliberately files another match under this key.
        await database.savePublicSnapshot(
          'public:match-detail:$_match',
          jsonEncode({
            'matchId': available ? 'fb_match_other245' : _match,
            'available': available,
            'home': {
              'starters': [
                {
                  'id': _player,
                  'canonicalId': _player,
                  'name': 'Persona sintética',
                  'image': _oldImage,
                },
              ],
            },
            'away': <String, dynamic>{},
          }),
        );
        expect(await repository.readStoredMatchDetail(_match), isNull);
        expect(media.imageFor(_player), _newImage);
        expect(media.redirects.resolve(_alias), _newTarget);
      } finally {
        dio.close(force: true);
        media.dispose();
        await database.close();
      }
    });
  }

  for (final entity in [false, true]) {
    test(
      'rejected old ${entity ? 'entity' : 'context'} cannot mutate accepted shared media or redirects',
      () async {
        final database = AppDatabase(NativeDatabase.memory());
        final media = EntityMediaMemory();
        final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
        final firstStarted = Completer<void>();
        final releaseOld = Completer<void>();
        var requests = 0;
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) async {
              final sequence = ++requests;
              if (sequence == 1) {
                firstStarted.complete();
                await releaseOld.future;
              }
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: _payload(current: sequence > 1),
                ),
              );
            },
          ),
        );
        final repository = ApiRepository(
          dio,
          database,
          const CalendarCachePolicy(),
          media,
        );
        Future<Snapshot> load() => entity
            ? repository.loadEntity('team', _team)
            : repository.loadMatchContext(_match);
        try {
          final old = load();
          await firstStarted.future;
          final current = await load();
          expect(media.imageFor(_player), _newImage);
          expect(media.redirects.resolve(_alias), _newTarget);
          releaseOld.complete();
          final rejected = await old;
          expect(rejected.updatedAt, current.updatedAt);
          expect(rejected.stale, isTrue);
          expect(media.imageFor(_player), _newImage);
          expect(media.redirects.resolve(_alias), _newTarget);
          await repository.settleBackground();
          final cacheKey = entity
              ? 'entity:team:$_team'
              : 'match-context:$_match';
          final stored = await database.readPublicSnapshot('public:$cacheKey');
          expect(stored, isNotNull);
          final persisted = jsonDecode(stored!.payload) as Json;
          expect(
            DateTime.parse(persisted['updatedAt'] as String),
            current.updatedAt,
          );
          expect((persisted['entityRedirects'] as Map)[_alias], _newTarget);
          expect(requests, 2);
        } finally {
          if (!releaseOld.isCompleted) releaseOld.complete();
          await repository.settleBackground();
          dio.close(force: true);
          media.dispose();
          await database.close();
        }
      },
    );
  }
}

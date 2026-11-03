import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/entity_media.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';

const _probe = 'fb_player_probe261';
const _alias = 'fb_team_probe_alias261';
const _photo = 'https://media.example.test/entity-foreign261.png';
Json _entity(
  String type,
  String? id,
  String stamp, {
  bool poison = false,
  String? requestedAlias,
}) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': stamp,
  'teams': [
    if (type == 'team' && id != null) {'id': id, 'name': 'Same synthetic name'},
  ],
  'players': [
    if (type == 'player' && id != null)
      {'id': id, 'name': 'Same synthetic name'},
    if (poison)
      {
        'id': _probe,
        'name': 'Synthetic probe',
        'media': {'url': _photo, 'verificationStatus': 'VERIFIED'},
      },
  ],
  'competitions': [
    if (type == 'competition' && id != null)
      {'id': id, 'name': 'Same synthetic name'},
  ],
  'matches': [],
  'standings': [],
  if (poison || requestedAlias != null)
    'entityRedirects': {
      if (poison) _alias: 'fb_team_foreign_marker261',
      ?requestedAlias: id,
    },
};

class _Fixture {
  _Fixture(this.answers) : db = AppDatabase(NativeDatabase.memory()) {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          requests.add(request);
          handler.resolve(
            Response(
              requestOptions: request,
              data: answers[requests.length - 1],
            ),
          );
        },
      ),
    );
    repository = ApiRepository(dio, db, const CalendarCachePolicy(), media);
  }
  final List<Json> answers;
  final AppDatabase db;
  final Dio dio = Dio();
  final EntityMediaMemory media = EntityMediaMemory();
  late final ApiRepository repository;
  final requests = <RequestOptions>[];
  Future<void> close() async {
    await repository.settleBackground();
    dio.close(force: true);
    media.dispose();
    await db.close();
  }
}

void main() {
  for (final type in ['team', 'player', 'competition']) {
    final requested = 'fb_${type}_requested261';
    final foreign = 'fb_${type}_foreign261';
    Entity? target(Snapshot data) => switch (type) {
      'team' => data.team(requested),
      'player' => data.player(requested),
      _ => data.competition(requested),
    };
    test(
      '$type foreign context is rejected before media redirects or requested cache acceptance',
      () async {
        final f = _Fixture([
          _entity(type, foreign, '2026-11-03T23:00:00Z', poison: true),
        ]);
        addTearDown(f.close);
        await expectLater(
          f.repository.loadEntity(type, requested),
          throwsA(isA<FormatException>()),
        );
        expect(f.media.imageFor(_probe), isNull);
        expect(f.media.redirects.resolve(_alias), _alias);
        await f.repository.settleBackground();
        expect(
          await f.db.readPublicSnapshot('public:entity:$type:$requested'),
          isNull,
        );
        expect(f.requests, hasLength(1));
      },
    );
    test(
      '$type foreign timestamp cannot prevent later valid identity from loading',
      () async {
        final f = _Fixture([
          _entity(type, foreign, '2026-11-03T23:00:00Z', poison: true),
          _entity(type, requested, '2026-11-03T20:00:00Z'),
        ]);
        addTearDown(f.close);
        try {
          await f.repository.loadEntity(type, requested);
        } on FormatException {
          /* expected after identity validation */
        }
        final corrected = await f.repository.loadEntity(type, requested);
        expect(
          target(corrected)?.id,
          requested,
          reason: 'foreign newer timestamp must not poison the requested memory key',
        );
        expect(corrected.updatedAt, DateTime.parse('2026-11-03T20:00:00Z'));
        await f.repository.settleBackground();
        final persisted = await f.db.readPublicSnapshot(
          'public:entity:$type:$requested',
        );
        if (type == 'competition') {
          expect(persisted, isNull);
          return;
        }
        expect(persisted, isNotNull);
        expect(
          (jsonDecode(persisted!.payload) as Map)['updatedAt'],
          '2026-11-03T20:00:00Z',
        );
      },
    );
    test(
      '$type foreign context preserves known requested data and cannot block newer valid data',
      () async {
        final f = _Fixture([
          _entity(type, requested, '2026-11-03T20:00:00Z'),
          _entity(type, foreign, '2026-11-03T23:00:00Z', poison: true),
          _entity(type, requested, '2026-11-03T21:00:00Z'),
        ]);
        addTearDown(f.close);
        await f.repository.loadEntity(type, requested);
        final held = await f.repository.loadEntity(type, requested);
        expect(target(held)?.id, requested);
        expect(held.stale, isTrue);
        expect(f.media.imageFor(_probe), isNull);
        expect(f.media.redirects.resolve(_alias), _alias);
        final current = await f.repository.loadEntity(type, requested);
        expect(target(current)?.id, requested);
        expect(current.updatedAt, DateTime.parse('2026-11-03T21:00:00Z'));
      },
    );
    test(
      '$type explicit canonical redirect remains an accepted entity context',
      () async {
        final f = _Fixture([
          _entity(
            type,
            foreign,
            '2026-11-03T23:00:00Z',
            requestedAlias: requested,
          ),
        ]);
        addTearDown(f.close);
        final data = await f.repository.loadEntity(type, requested);
        expect(target(data)?.id, foreign);
        expect(data.resolveEntityId(requested), foreign);
        await f.repository.settleBackground();
        expect(
          await f.db.readPublicSnapshot('public:entity:$type:$requested'),
          type == 'competition' ? isNull : isNotNull,
        );
      },
    );
    test(
      '$type full snapshot may include related entities when requested identity exists',
      () async {
        final payload = _entity(
          type,
          requested,
          '2026-11-03T20:00:00Z',
          poison: true,
        );
        final bucket = switch (type) {
          'team' => 'teams',
          'player' => 'players',
          _ => 'competitions',
        };
        (payload[bucket] as List).add({
          'id': foreign,
          'name': 'Same synthetic name',
        });
        final f = _Fixture([payload]);
        addTearDown(f.close);
        final data = await f.repository.loadEntity(type, requested);
        expect(target(data)?.id, requested);
        expect(f.media.imageFor(_probe), _photo);
        expect(f.requests, hasLength(1));
      },
    );
    test('$type empty no-data context remains legitimate', () async {
      final f = _Fixture([_entity(type, null, '2026-11-03T23:00:00Z')]);
      addTearDown(f.close);
      final data = await f.repository.loadEntity(type, requested);
      expect(target(data), isNull);
      expect(data.matches, isEmpty);
      expect(f.requests, hasLength(1));
    });
  }
}

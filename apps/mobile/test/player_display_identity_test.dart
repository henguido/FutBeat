import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/entity_media.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/player_display_identity.dart';
import 'package:futbeat/core/providers.dart';

const _saprissa = 'fb_team_7d7cf628b4cb43e3a30cfade12eb0cf6';
const _waston = 'fb_player_333ccb5b7044465497e7888298dc7f87';
const _wastonAlias = 'fb_player_a7a7c8d3a8474ef68c968dca80d2e975';
const _libertad = 'fb_team_3b8b2297604342438483d4d413ac4d19';
const _vera = 'fb_player_acca8c458fc64beaa46d01ad4e8650aa';
const _veraAlias = 'fb_player_57babfbf15f049af900b7316bad49471';

Map<String, dynamic> _player(
  String id,
  String name,
  String team,
  int shirt, {
  String? dob,
  Object? media,
}) => {
  'id': id,
  'name': name,
  'teamId': team,
  'shirtNumber': shirt,
  'country': '',
  'dateOfBirth': ?dob,
  'media': ?media,
};

Map<String, dynamic> _snapshot(List<Map<String, dynamic>> players) => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': '2026-10-03T07:00:00Z',
  'entityRedirects': <String, dynamic>{},
  'coverage': {
    'squad': {'state': 'AVAILABLE', 'playerCount': players.length},
  },
  'teams': <dynamic>[],
  'players': players,
  'competitions': <dynamic>[],
  'matches': <dynamic>[],
  'standings': <dynamic>[],
};

void main() {
  final richWaston = _player(
    _waston,
    'Jamaal Waston Manley Kendall',
    _saprissa,
    4,
    dob: '1988-01-01',
    media: {
      'verificationStatus': 'VERIFIED',
      'url': 'https://media.example.test/waston.png',
    },
  );
  final sparseWaston = _player(_wastonAlias, 'Waston Kendall', _saprissa, 4);
  final richVera = _player(
    _vera,
    'Rodrigo Vera Oscar',
    _libertad,
    30,
    dob: '2007-12-14',
  );
  final shortVera = _player(
    _veraAlias,
    'Rodrigo Vera',
    _libertad,
    30,
    dob: '2007-12-14',
  );

  test('two independently adjudicated real pairs yield one visible row', () {
    for (final pair in [
      [sparseWaston, richWaston],
      [shortVera, richVera],
    ]) {
      final shown = presentPlayers(pair);
      expect(shown, hasLength(1));
      expect(shown.single['id'], pair.last['id']);
      final reverse = presentPlayers(pair.reversed);
      expect(reverse, hasLength(1));
      expect(reverse.single['id'], pair.last['id']);
    }
  });

  test('similar surname and shirt do not adjudicate strangers', () {
    final rows = [
      _player('fb_player_one', 'Juan Vera', _libertad, 30),
      _player('fb_player_two', 'Juan Vera Oscar', _libertad, 30),
    ];
    expect(presentPlayers(rows), hasLength(2));
  });

  test('conflicting DOB never collapses an adjudicated pair', () {
    final conflict = {...shortVera, 'dateOfBirth': '2006-01-01'};
    final shown = presentPlayers([conflict, richVera]);
    expect(shown.map((row) => row['id']), containsAll([_veraAlias, _vera]));
    expect(visiblePlayerAliases([conflict, richVera]), isEmpty);
  });

  test('conflicting country or position fails open', () {
    for (final field in const ['country', 'position']) {
      final a = {...shortVera, field: 'value-one'};
      final b = {...richVera, field: 'value-two'};
      expect(presentPlayers([a, b]), hasLength(2));
    }
  });

  test('actual Haras El Hodood DOB conflict remains two people', () {
    final rows = [
      _player(
        'fb_player_ad3770b8090b4cb49e4ace054f179cf1',
        'Mohamed Ahmed Kamel',
        'fb_team_0cc1f88b51304f56bbfae17b0e2cf8fa',
        32,
        dob: '1990-11-20',
      ),
      _player(
        'fb_player_b0b7a9592ffb4ed39d66de52b0e68dd2',
        'Ahmed Kamel',
        'fb_team_0cc1f88b51304f56bbfae17b0e2cf8fa',
        32,
        dob: '1990-01-01',
      ),
    ];
    expect(presentPlayers(rows), hasLength(2));
  });

  test('same names in different teams never collapse', () {
    final elsewhere = {...shortVera, 'teamId': _saprissa};
    expect(presentPlayers([elsewhere, richVera]), hasLength(2));
  });

  test('a later conflict revokes a previously learned display redirect', () {
    final memory = EntityMediaMemory();
    memory.absorb(Snapshot(_snapshot([sparseWaston, richWaston])));
    expect(memory.redirects.resolve(_wastonAlias), _waston);
    expect(memory.imageFor(_wastonAlias), isNotNull);

    memory.absorb(
      Snapshot(
        _snapshot([
          {...sparseWaston, 'dateOfBirth': '1990-01-01'},
          richWaston,
        ]),
      ),
    );
    expect(memory.redirects.resolve(_wastonAlias), _wastonAlias);
    expect(memory.imageFor(_wastonAlias), isNull);
    memory.dispose();
  });

  test('target-only DOB or country drift revokes a learned alias', () {
    for (final change in [
      {'dateOfBirth': '1990-01-01'},
      {'country': 'Different country'},
      {'position': 'Goalkeeper'},
    ]) {
      final memory = EntityMediaMemory();
      final originalAlias = {
        ...sparseWaston,
        'country': 'Costa Rica',
        'position': 'Defender',
      };
      final originalTarget = {
        ...richWaston,
        'country': 'Costa Rica',
        'position': 'Defender',
      };
      memory.absorb(Snapshot(_snapshot([originalAlias, originalTarget])));
      expect(memory.redirects.resolve(_wastonAlias), _waston);
      memory.absorb(
        Snapshot(
          _snapshot([
            {...originalTarget, ...change},
          ]),
        ),
      );
      expect(
        memory.redirects.resolve(_wastonAlias),
        _wastonAlias,
        reason: change.toString(),
      );
      expect(memory.imageFor(_wastonAlias), isNull);
      memory.dispose();
    }
  });

  test('snapshot keeps counts, search identity, and navigation coherent', () {
    final squad = Snapshot(
      _snapshot([sparseWaston, richWaston, shortVera, richVera]),
    );
    expect(squad.players, hasLength(2));
    expect(squad.coverage?['squad']['playerCount'], 2);
    expect(squad.resolveEntityId(_wastonAlias), _waston);
    expect(squad.resolveEntityId(_veraAlias), _vera);
    expect(squad.player(_waston)?.name, 'Jamaal Waston Manley Kendall');
    expect(squad.player(_wastonAlias)?.id, _waston);

    final search = Snapshot(_snapshot([sparseWaston]));
    expect(search.players.single.id, _waston);
    expect(search.players.single.name, 'Jamaal Waston Manley Kendall');
    expect(search.resolveEntityId(_wastonAlias), _waston);
    expect(search.coverage?['squad']['playerCount'], 1);
  });

  test('match-context event IDs follow the same visible identity', () {
    final raw = _snapshot([sparseWaston, richWaston]);
    raw['matches'] = [
      {
        'events': [
          {
            'playerId': _wastonAlias,
            'assistPlayerId': _wastonAlias,
            'playerName': 'Waston Kendall',
          },
        ],
      },
    ];
    final presented = presentPlayerSnapshot(raw);
    final event =
        ((presented['matches'] as List).single['events'] as List).single as Map;
    expect(event['playerId'], _waston);
    expect(event['assistPlayerId'], _waston);
    expect(
      event['playerName'],
      'Waston Kendall',
      reason: 'provider text is preserved; entity supplies display name',
    );
  });

  test(
    'lineup uses the same display identity without changing provider key',
    () {
      final detail = MatchDetail({
        'home': {
          'starters': [
            {
              'canonicalId': _wastonAlias,
              'name': 'Kendall Waston',
              'number': 4,
              'playerKey': 'goal-provider-key',
            },
          ],
        },
        'away': {'starters': <dynamic>[]},
      });
      expect(detail.homeStarters.single['canonicalId'], _waston);
      expect(
        detail.homeStarters.single['name'],
        'Jamaal Waston Manley Kendall',
      );
      expect(detail.homeStarters.single['playerKey'], 'goal-provider-key');
    },
  );

  test('lineup keeps the selected row when both provider IDs appear', () {
    final detail = MatchDetail({
      'home': {
        'starters': [
          {'canonicalId': _wastonAlias, 'name': 'Waston Kendall', 'number': 4},
          {
            'canonicalId': _waston,
            'name': 'Jamaal Waston Manley Kendall',
            'number': 4,
            'rating': 7.5,
          },
        ],
        'substitutes': <dynamic>[],
      },
      'away': {'starters': <dynamic>[]},
    });
    expect(detail.homeStarters, hasLength(1));
    expect(detail.homeStarters.single['canonicalId'], _waston);
    expect(detail.homeStarters.single['rating'], 7.5);
  });

  test(
    'an alias deep link loads the richer profile and fails open on drift',
    () async {
      var conflictingTarget = false;
      final requests = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final id = request.uri.queryParameters['id'] ?? '';
        requests.add(id);
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(
            _snapshot([
              id == _wastonAlias
                  ? sparseWaston
                  : conflictingTarget
                  ? {...richWaston, 'dateOfBirth': '1990-01-01'}
                  : richWaston,
            ]),
          ),
        );
        await request.response.close();
      });
      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
      try {
        final good = await ApiRepository(dio)
            .loadEntity('player', _wastonAlias);
        expect(requests, [_wastonAlias, _waston]);
        expect(good.resolveEntityId(_wastonAlias), _waston);
        expect(good.player(_waston)?.json['dateOfBirth'], '1988-01-01');

        conflictingTarget = true;
        requests.clear();
        final changed = await ApiRepository(dio)
            .loadEntity('player', _wastonAlias);
        expect(requests, [_wastonAlias, _waston]);
        expect(changed.resolveEntityId(_wastonAlias), _wastonAlias);
        expect(changed.player(_wastonAlias)?.name, 'Waston Kendall');
      } finally {
        dio.close(force: true);
        await server.close(force: true);
      }
    },
  );
}

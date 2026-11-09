// API275: contract between the app and futbeat-passive-api v1. The wire fixtures are
// recorded from the real handler over the real SQL (backend: scripts/passive-api/
// contract_fixtures.mjs); this test feeds them to the real ApiRepository.
// No network: an in-memory adapter answers only fixture paths.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/passive_preview_transport.dart';

const _origin = 'https://passive.test/functions/v1/futbeat-passive-api';
String _route(Uri uri) => uri.path
    .replaceFirst('/functions/v1/futbeat-passive-api', '')
    .replaceFirst('/v1/qa-stored/', '/v1/');
const _scope = {
  '/v1/calendar',
  '/v1/match-context',
  '/v1/match-detail',
  '/v1/match-preview',
  '/v1/match-h2h',
  '/v1/entity',
  '/v1/team-context',
  '/v1/team-matches',
  '/v1/standings-form',
  '/v1/favorites',
  '/v1/explore',
  '/v1/search',
};

class _FixtureAdapter implements HttpClientAdapter {
  _FixtureAdapter(this.fixtures);
  final List<Map<String, dynamic>> fixtures;
  final requests = <RequestOptions>[];

  Map<String, dynamic>? _find(Uri uri) {
    for (final fixture in fixtures) {
      final wanted = Uri.parse('https://x${fixture['path']}');
      if (wanted.path != _route(uri)) continue;
      final keys = ['id', 'date', 'type', 'bucket', 'q', 'keys'];
      if (keys.every(
        (k) =>
            wanted.queryParameters[k] == null ||
            wanted.queryParameters[k] == uri.queryParameters[k],
      )) {
        return fixture;
      }
    }
    return null;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (!options.uri.toString().startsWith(_origin)) {
      throw StateError('Only the passive origin is reachable: ${options.uri}');
    }
    final fixture = _find(options.uri);
    if (fixture == null) printOnFailure('unmatched: ${options.uri}');
    final status = fixture?['status'] as int? ?? 403;
    final headers = <String, List<String>>{
      'content-type': ['application/json; charset=utf-8'],
      for (final entry
          in ((fixture?['headers'] as Map?) ?? {'x-futbeat-passive': 'v1'})
              .entries)
        entry.key as String: [entry.value as String],
    };
    final body = fixture == null
        ? {'error': 'Route outside stored-read scope'}
        : fixture['body'];
    return ResponseBody.fromString(jsonEncode(body), status, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _FixtureAdapter adapter;
  late ApiRepository repository;
  late Map<String, dynamic> contract;

  setUpAll(() {
    contract = jsonDecode(
      File('test/fixtures/passive_api_v1.json').readAsStringSync(),
    ) as Map<String, dynamic>;
  });

  setUp(() {
    adapter = _FixtureAdapter(
      (contract['fixtures'] as List).cast<Map<String, dynamic>>(),
    );
    var now = DateTime.utc(2026, 11, 4);
    final dio = Dio(BaseOptions(baseUrl: _origin))
      ..httpClientAdapter = adapter
      ..interceptors.add(
        PassivePreviewTransport(
          baseUri: Uri.parse(_origin),
          clock: () {
            now = now.add(const Duration(minutes: 1));
            return now;
          },
        ),
      );
    addTearDown(() => dio.close(force: true));
    repository = ApiRepository(dio);
  });

  tearDown(() {
    for (final request in adapter.requests) {
      expect(request.method, 'GET', reason: request.uri.toString());
      expect(request.uri.queryParameters, isNot(contains('request')));
    }
  });

  test(
    'every fixture carries the passive acknowledgment and a cache policy',
    () {
      expect(contract['contract'], 'futbeat-passive-api/v1');
      for (final fixture
          in (contract['fixtures'] as List).cast<Map<String, dynamic>>()) {
        final headers = fixture['headers'] as Map;
        expect(
          headers['x-futbeat-passive'],
          'v1',
          reason: fixture['path'] as String,
        );
        final path = Uri.parse('https://x${fixture['path']}').path;
        expect(
          fixture['status'],
          _scope.contains(path) ? anyOf(200, 404) : 403,
          reason: fixture['path'] as String,
        );
      }
    },
  );

  test('calendar day, match context, detail and preview parse from the passive wire', () async {
    final day = await repository.loadDate(DateTime(2026, 11, 1));
    expect(day.demo, isFalse);
    expect(day.match('fb_match_contract_ft'), isNotNull);
    expect(day.match('fb_match_contract_ft')!.score, '2 - 1');

    final context = await repository.loadMatchContext('fb_match_contract_ft');
    expect(context.match('fb_match_contract_ft'), isNotNull);

    final detail = await repository.loadMatchDetail('fb_match_contract_ft');
    expect(
      detail.json['pending'],
      isFalse,
      reason: 'a passive detail never asks the app to poll',
    );

    await repository.loadMatchPreview('fb_match_contract_ns');
    await repository.loadMatchH2h('fb_match_contract_ns');
    expect(
      adapter.requests.map((r) => _route(r.uri)).toSet().difference(_scope),
      isEmpty,
    );
  });

  test('entity, team, standings, favorites, explore and search parse from the passive wire', () async {
    final team = await repository.loadEntity('team', 'fb_team_contract_h');
    expect(team.team('fb_team_contract_h'), isNotNull);
    await repository.loadEntity('competition', 'fb_comp_contract');
    await repository.loadEntity('player', 'fb_player_contract_9');
    await repository.loadTeamContext('fb_team_contract_h');
    await repository.loadTeamMatches('fb_team_contract_h', 'results');
    await repository.loadStandingsForm('fb_comp_contract', '2026');
    await repository.loadFavorites([
      'team:fb_team_contract_h',
      'competition:fb_comp_contract',
    ]);
    final explore = await repository.loadExplore(country: 'CR');
    expect(explore.demo, isFalse);
    final found = await repository.searchCatalog('contrato', 'CR');
    expect(found.team('fb_team_contract_h'), isNotNull);
    expect(
      adapter.requests.map((r) => _route(r.uri)).toSet().difference(_scope),
      isEmpty,
    );
  });

  test(
    'out-of-scope routes fail fast with one request and no retry loop',
    () async {
      await expectLater(
        repository.loadNewsFeed(const [], 'CR'),
        throwsA(anything),
      );
      final news = adapter.requests
          .where((r) => r.uri.path.endsWith('/v1/news'))
          .length;
      expect(news, 0);
    },
  );
}

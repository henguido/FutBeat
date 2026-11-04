import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/entity_media.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';

const _requested = 'fb_match_requested245';
const _foreign = 'fb_match_foreign245';
const _player = 'fb_player_detail245';
const _photo = 'https://media.example.test/detail245.png';

Json _detail(String id) => {
  'matchId': id,
  'available': true,
  'pending': false,
  'detailLevel': 'partial',
  'home': {
    'starters': [
      {
        'id': _player,
        'canonicalId': _player,
        'name': 'Persona sintética',
        'image': _photo,
      },
    ],
  },
  'away': <String, dynamic>{},
  'statistics': <Json>[],
  'incidents': <Json>[],
};

void main() {
  for (final readOnly in [false, true]) {
    test(
      '${readOnly ? 'read' : 'load'} rejects foreign detail before media/request/cache acceptance',
      () async {
        final database = AppDatabase(NativeDatabase.memory());
        final media = EntityMediaMemory();
        final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
        final requests = <RequestOptions>[];
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              requests.add(request);
              handler.resolve(
                Response(
                  requestOptions: request,
                  data: _detail(requests.length == 1 ? _foreign : _requested),
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
        Future<MatchDetail> load() => readOnly
            ? repository.readMatchDetail(_requested)
            : repository.loadMatchDetail(_requested);
        try {
          await expectLater(load(), throwsA(isA<FormatException>()));
          await repository.settleBackground();
          expect(requests, hasLength(1)); // No automatic retry or extra route.
          expect(media.imageFor(_player), isNull);
          expect(
            await database.readPublicSnapshot(
              'public:match-detail:$_requested',
            ),
            isNull,
          );
          expect(
            await database.readPublicSnapshot('public:match-detail:$_foreign'),
            isNull,
          );
          final accepted =
              await load(); // Explicit retry after corrected response.
          expect(accepted.matchId, _requested);
          expect(accepted.available, isTrue);
          expect(accepted.detailLevel, 'partial');
          expect(media.imageFor(_player), _photo);
          expect(requests, hasLength(2));
          // Rejected load did not set _detailRequested and switch its retry
          // to request=0. A read remains read-only on both attempts.
          expect(
            requests.last.queryParameters['request'],
            readOnly ? '0' : isNull,
          );
        } finally {
          await repository.settleBackground();
          dio.close(force: true);
          media.dispose();
          await database.close();
        }
      },
    );
  }

  for (final legacy in [false, true]) {
    test(
      'preserves ${legacy ? 'legacy missing-ID' : 'unavailable'} detail contract',
      () async {
        final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              handler.resolve(
                Response(
                  requestOptions: request,
                  data: {
                    ...MatchDetail.empty(_foreign).sourceJson,
                    if (legacy) 'matchId': '',
                    'available': legacy,
                  },
                ),
              );
            },
          ),
        );
        try {
          final detail = await ApiRepository(dio).readMatchDetail(_requested);
          expect(detail.available, legacy);
          expect(detail.matchId, legacy ? '' : _foreign);
        } finally {
          dio.close(force: true);
        }
      },
    );
  }
}

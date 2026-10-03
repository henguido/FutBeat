import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/entity_media.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';

const aliasId = 'fb_player_a7a7c8d3a8474ef68c968dca80d2e975';
const visibleId = 'fb_player_333ccb5b7044465497e7888298dc7f87';
const teamId = 'fb_team_7d7cf628b4cb43e3a30cfade12eb0cf6';

Map<String, dynamic> snapshot(List<Map<String, dynamic>> players) => {
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
  test(
    'cached lineup stays separated on both refresh and failed refresh',
    () async {
      for (final failRefresh in [false, true]) {
        final media = EntityMediaMemory();
        final alias = {
          'id': aliasId,
          'name': 'Waston Kendall',
          'teamId': teamId,
          'shirtNumber': 4,
          'country': '',
        };
        final visible = {
          'id': visibleId,
          'name': 'Jamaal Waston Manley Kendall',
          'teamId': teamId,
          'shirtNumber': 4,
          'dateOfBirth': '1988-01-01',
          'country': '',
        };
        media.absorb(Snapshot(snapshot([alias, visible])));
        final rawDetail = <String, dynamic>{
          'matchId': 'fb_match',
          'available': true,
          'pending': false,
          'detailLevel': 'full',
          'home': {
            'starters': [
              {'canonicalId': aliasId, 'name': 'Waston Kendall', 'number': 4},
              {
                'canonicalId': visibleId,
                'name': 'Jamaal Waston Manley Kendall',
                'number': 4,
              },
            ],
            'substitutes': <dynamic>[],
          },
          'away': {'starters': <dynamic>[], 'substitutes': <dynamic>[]},
        };
        final cached = MatchDetail(rawDetail);
        expect(cached.homeStarters, hasLength(1));
        media.absorb(
          Snapshot(
            snapshot([
              {...visible, 'dateOfBirth': '1990-01-01'},
            ]),
          ),
        );

        final dio = Dio();
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (failRefresh) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    type: DioExceptionType.connectionError,
                  ),
                );
              } else {
                handler.resolve(
                  Response(requestOptions: options, data: rawDetail),
                );
              }
            },
          ),
        );
        final container = ProviderContainer(
          overrides: [
            repositoryProvider.overrideWithValue(
              ApiRepository(dio, null, const CalendarCachePolicy(), media),
            ),
            matchDetailMemoryProvider.overrideWithValue({'fb_match': cached}),
          ],
        );
        final emissions = <int>[];
        final second = Completer<void>();
        final subscription = container.listen(matchDetailProvider('fb_match'), (
          previous,
          next,
        ) {
          final value = next.asData?.value;
          if (value == null) return;
          emissions.add(value.homeStarters.length);
          if (emissions.length >= 2 && !second.isCompleted) second.complete();
        }, fireImmediately: true);
        await second.future.timeout(const Duration(seconds: 5));
        expect(emissions.take(2), [2, 2], reason: 'failRefresh=$failRefresh');
        subscription.close();
        container.dispose();
        media.dispose();
        dio.close(force: true);
      }
    },
  );

  testWidgets('an already-open view updates after an alias is revoked', (
    tester,
  ) async {
    final memory = EntityMediaMemory();
    addTearDown(memory.dispose);
    final alias = {
      'id': aliasId,
      'name': 'Waston Kendall',
      'teamId': teamId,
      'shirtNumber': 4,
      'country': '',
    };
    final visible = {
      'id': visibleId,
      'name': 'Jamaal Waston Manley Kendall',
      'teamId': teamId,
      'shirtNumber': 4,
      'dateOfBirth': '1988-01-01',
      'country': '',
    };
    final earlier = Snapshot(snapshot([alias, visible]));
    memory.absorb(earlier);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [entityMediaProvider.overrideWithValue(memory)],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) => Text(
              '${presentSnapshotForSession(ref, earlier).players.length}',
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('1'), findsOneWidget);

    memory.absorb(
      Snapshot(
        snapshot([
          {...visible, 'dateOfBirth': '1990-01-01'},
        ]),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('2'), findsOneWidget);
  });
}

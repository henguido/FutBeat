import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/providers.dart';

import 'r4_coverage_contract_test.dart' show preview;

void main() {
  for (final policy in [
    'no-store',
    'private, max-age=30',
    'public, max-age=30, no-cache',
  ]) {
    test('stale H2H obeys backend cache policy: $policy', () async {
      final db = AppDatabase(NativeDatabase.memory());
      final dio = Dio();
      addTearDown(db.close);
      addTearDown(() => dio.close(force: true));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            h.resolve(
              Response(
                requestOptions: o,
                data: preview(availability: 'STALE'),
                headers: Headers.fromMap({
                  'cache-control': [policy],
                }),
              ),
            );
          },
        ),
      );
      expect(
        (await ApiRepository(dio, db).loadMatchPreview('fb_match')).h2hMeetings,
        isNotEmpty,
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        await db.readPublicSnapshot('public:match-preview:fb_match'),
        isNull,
      );
    });
  }
  test('public stale H2H survives offline without becoming fresh or renewing savedAt', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final dio = Dio();
    addTearDown(db.close);
    addTearDown(() => dio.close(force: true));
    var offline = false;
    var calls = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) {
          calls++;
          if (offline) {
            h.reject(
              DioException(
                requestOptions: o,
                type: DioExceptionType.connectionError,
              ),
            );
          } else {
            h.resolve(
              Response(
                requestOptions: o,
                data: preview(availability: 'STALE'),
                headers: Headers.fromMap({
                  'cache-control': ['public, max-age=30'],
                }),
              ),
            );
          }
        },
      ),
    );
    final repo = ApiRepository(dio, db);
    expect((await repo.loadMatchPreview('fb_match')).h2hAvailability, 'STALE');
    await repo.settleBackground();
    const key = 'public:match-preview:fb_match';
    final saved = await db.readPublicSnapshot(key);
    expect(saved, isNotNull);
    offline = true;
    final restored = await ApiRepository(dio, db).loadMatchPreview('fb_match');
    expect(restored.h2hAvailability, 'STALE');
    expect(restored.h2hMeetings.single['matchId'], 'fb_match_previous');
    expect(calls, 2, reason: 'Stale history is revalidated even inside TTL');
    expect((await db.readPublicSnapshot(key))!.savedAt, saved!.savedAt);
    expect(
      jsonDecode(
        (await db.readPublicSnapshot(key))!.payload,
      )['h2h']['availability'],
      'STALE',
    );
  });
}

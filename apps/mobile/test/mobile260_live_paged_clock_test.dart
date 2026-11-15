import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/models.dart';

import 'live_bootstrap_test.dart' show liveRow;

void main() {
  for (final mode in ['date', 'missing', 'failure']) {
    test('paged LIVE uses final response clock ($mode)', () async {
      final start = DateTime.utc(2026, 11, 3, 12);
      final end = start.add(const Duration(seconds: 20));
      final row = liveRow(
        'fb_match_page_clock260',
        updatedAt: start.subtract(const Duration(minutes: 14, seconds: 50)),
      );
      final dio = Dio();
      addTearDown(() => dio.close(force: true));
      var pages = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            final first = pages++ == 0;
            if (!first && mode == 'failure') {
              handler.reject(DioException(requestOptions: request));
              return;
            }
            handler.resolve(
              Response(
                requestOptions: request,
                data: first ? [row] : <Json>[],
                statusCode: 200,
                headers: Headers.fromMap({
                  if (first || mode == 'date')
                    'date': [HttpDate.format(first ? start : end)],
                }),
              ),
            );
          },
        ),
      );
      final read = await fetchLiveBootstrap(
        dio,
        const LiveRealtimeConfig(
          supabaseUrl: 'http://localhost',
          publicKey: 'fixture',
        ),
        const LiveBootstrapPolicy(pageSize: 1),
        since: start.subtract(const Duration(days: 1)),
      );
      expect(read.complete, mode != 'failure');
      expect(pages, 2);
      final overlays = reconcileLiveBootstrapSnapshot(
        {},
        read.rows,
        deviceNow: end,
        serverNow: read.serverNow,
      );
      expect(
        end.difference(overlays.values.single.receivedAt!),
        greaterThan(LiveMatchUpdate.staleAfter),
        reason: 'paging latency cannot make an old score appear fresh',
      );
      expect(read.serverNow, mode == 'date' ? end : null);
    });
  }
}

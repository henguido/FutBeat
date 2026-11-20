import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/qa_development.dart';

const _id = 'fb_match_stop245';

/// Owned in-memory transport only. The held read has no physical socket and
/// can only finish after explicit teardown; Dio's cancellation must end it.
class _HeldStoredRead implements HttpClientAdapter {
  _HeldStoredRead({required this.partialFirst});
  final bool partialFirst;
  final held = Completer<void>();
  final release = Completer<void>();
  final paths = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancellation,
  ) async {
    paths.add(options.path);
    if (!partialFirst || paths.length > 1) {
      if (!held.isCompleted) held.complete();
      await release.future;
    }
    return ResponseBody.fromString(
      jsonEncode({
        'matchId': _id,
        'available': true,
        'pending': true,
        'hydrationNeeded': true,
        'detailLevel': 'partial',
        'coverage': {'storedRead': true},
        'home': <String, dynamic>{},
        'away': <String, dynamic>{},
        'statistics': <Json>[],
        'incidents': <Json>[],
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        'x-futbeat-qa-stored': ['v1'],
      },
    );
  }

  @override
  void close({bool force = false}) {
    if (!release.isCompleted) release.complete();
  }
}

void main() {
  for (final duringPoll in [false, true]) {
    test(
      'policy STOP during ${duringPoll ? 'poll' : 'initial read'} ends provider scheduling',
      () async {
        final wire = _HeldStoredRead(partialFirst: duringPoll);
        final origin = Uri.parse('https://127.0.0.1:9');
        final policy = QaStoredReadInterceptor(
          origin: origin,
          sessionLimit: 30,
          minuteLimit: 8,
          concurrentLimit: 2,
          sessionDuration: const Duration(minutes: 15),
        );
        final dio = Dio(BaseOptions(baseUrl: origin.toString()))
          ..httpClientAdapter = wire
          ..interceptors.add(policy);
        final memory = <String, MatchDetail>{};
        final container = ProviderContainer(
          overrides: [
            repositoryProvider.overrideWithValue(ApiRepository(dio)),
            matchDetailMemoryProvider.overrideWithValue(memory),
            detailPollScheduleProvider.overrideWithValue(const [
              Duration.zero,
              Duration.zero,
              Duration.zero,
              Duration.zero,
            ]),
          ],
        );
        final finished = Completer<MatchDetail>();
        final subscription = container.listen(matchDetailProvider(_id), (
          previous,
          next,
        ) {
          final detail = next.asData?.value;
          if (detail != null && !detail.pending && !finished.isCompleted) {
            finished.complete(detail);
          }
        });
        try {
          await wire.held.future.timeout(const Duration(seconds: 5));
          // STOP originates outside the screen and cancels its active HTTP read.
          // It must not turn into a series of freshly allocated blocked tokens.
          policy.close();
          final detail = await finished.future.timeout(
            const Duration(seconds: 5),
          );
          expect(detail.pending, isFalse);
          expect(detail.available, duringPoll);
          if (duringPoll) {
            expect(detail.hydrationNeeded, isTrue);
            expect(detail.json['coverage']['storedRead'], isTrue);
            expect(memory[_id]?.available, isTrue);
          }
          expect(wire.paths, hasLength(duringPoll ? 2 : 1));
          expect(wire.paths, everyElement('/v1/qa-stored/match-detail'));
          expect(policy.counters, {
            'requests': duringPoll ? 2 : 1,
            'active': 0,
            'blocked': 0,
          });
        } finally {
          policy.close();
          subscription.close();
          container.dispose();
          dio.close(force: true);
        }
      },
    );
  }
}

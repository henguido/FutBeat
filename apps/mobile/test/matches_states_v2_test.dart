import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/matches_screen.dart';

// Keep the selected calendar day and its synthetic match on the same date.
// A fixed 2026-10-07 day paired with DateTime.now() made these tests start
// failing as soon as the real clock advanced to 2026-10-08.
final _suiteClock = DateTime.now();
final _today = DateTime(
  _suiteClock.year,
  _suiteClock.month,
  _suiteClock.day + 1,
);
final _todayKey =
    '${_today.year.toString().padLeft(4, '0')}-'
    '${_today.month.toString().padLeft(2, '0')}-'
    '${_today.day.toString().padLeft(2, '0')}';

Snapshot _data({
  String? status,
  bool stale = false,
  bool revalidating = false,
}) {
  final payload = <String, dynamic>{
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': '2026-10-07T12:00:00Z',
    'freshness': {'stale': stale, 'revalidating': revalidating},
    'competitions': [
      {'id': 'competition', 'name': 'Liga FutBeat', 'countryCode': 'CR'},
    ],
    'teams': [
      {'id': 'home', 'name': 'Local'},
      {'id': 'away', 'name': 'Visitante'},
    ],
    'players': <dynamic>[],
    'matches': status == null
        ? <dynamic>[]
        : [
            {
              'id': 'match',
              'competitionId': 'competition',
              'homeTeamId': 'home',
              'awayTeamId': 'away',
              // Tomorrow at noon is both in the selected calendar day and
              // safely upcoming according to Match.isUpcoming's real clock.
              'startTime': _today
                  .add(const Duration(hours: 12))
                  .toUtc()
                  .toIso8601String(),
              'status': status,
              'events': <dynamic>[],
              'statistics': <dynamic>[],
            },
          ],
    'standings': <dynamic>[],
  };
  return Snapshot(payload);
}

Future<void> _pump(
  WidgetTester tester,
  Stream<Snapshot> Function() stream, {
  double width = 390,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        calendarSnapshotProvider.overrideWith((ref, date) => stream()),
        liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
        followsProvider.overrideWith((ref) => Stream.value(<String>{})),
        temporaryInterestsProvider.overrideWith(
          (ref) => Stream.value(<String>{}),
        ),
        preferenceProvider.overrideWith(
          (ref) => Stream.value(
            const CountryPreference(
              detectedCountry: 'CR',
              selectedCountry: null,
              bootstrapDismissed: true,
            ),
          ),
        ),
      ],
      child: MaterialApp(home: MatchesScreen(now: () => _today)),
    ),
  );
}

void main() {
  testWidgets('initial loading uses a bounded competition-shaped skeleton', (
    tester,
  ) async {
    final controller = StreamController<Snapshot>();
    addTearDown(controller.close);
    await _pump(tester, () => controller.stream);
    await tester.pump();

    expect(
      find.byKey(const ValueKey('matches-loading-skeleton')),
      findsOneWidget,
    );
    expect(find.text('Cargando partidos'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('refresh with cached matches keeps the feed and thin indicator', (
    tester,
  ) async {
    await _pump(
      tester,
      () => Stream.value(_data(status: 'SCHEDULED', revalidating: true)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const ValueKey('match-row-match')), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      find.byKey(const ValueKey('matches-loading-skeleton')),
      findsNothing,
    );
  });

  testWidgets('real empty day is distinct and contains no feed ad', (
    tester,
  ) async {
    await _pump(tester, () => Stream.value(_data()));
    await tester.pumpAndSettle();

    expect(find.text('No hay partidos para este día.'), findsOneWidget);
    expect(find.byKey(const ValueKey('matches-empty-day')), findsOneWidget);
    expect(find.byKey(ValueKey('feed-ad-$_todayKey-0')), findsNothing);
  });

  testWidgets('filters have specific empty states and return to Todos', (
    tester,
  ) async {
    await _pump(tester, () => Stream.value(_data(status: 'SCHEDULED')));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, 'En vivo'));
    await tester.pumpAndSettle();
    expect(find.text('No hay partidos en vivo ahora.'), findsOneWidget);
    expect(find.text('No hay partidos para este día.'), findsNothing);

    await tester.tap(find.text('Ver todos'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Finalizados'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Finalizados'));
    await tester.pumpAndSettle();
    expect(find.text('No hay partidos finalizados.'), findsOneWidget);

    await tester.tap(find.text('Ver todos'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Próximos'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Próximos'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('match-row-match')), findsOneWidget);
  });

  testWidgets('error without cache uses generic copy and retry recovers', (
    tester,
  ) async {
    var attempts = 0;
    await _pump(tester, () {
      attempts++;
      return attempts == 1
          ? Stream<Snapshot>.error(StateError('server'))
          : Stream.value(_data(status: 'SCHEDULED'));
    });
    await tester.pumpAndSettle();

    expect(find.text('No pudimos cargar los partidos.'), findsOneWidget);
    expect(find.text('Sin conexión.'), findsNothing);
    expect(find.byKey(const ValueKey('matches-load-error')), findsOneWidget);
    expect(find.byKey(ValueKey('feed-ad-$_todayKey-0')), findsNothing);

    await tester.tap(find.text('Reintentar'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('match-row-match')), findsOneWidget);
    expect(attempts, 2);
  });

  testWidgets('only a proven connection failure uses offline copy', (
    tester,
  ) async {
    final error = DioException(
      requestOptions: RequestOptions(path: '/v1/calendar'),
      type: DioExceptionType.connectionError,
      message: 'network unreachable',
    );
    await _pump(tester, () => Stream<Snapshot>.error(error));
    await tester.pumpAndSettle();

    expect(find.text('Sin conexión.'), findsOneWidget);
    expect(find.text('No pudimos cargar los partidos.'), findsNothing);
  });

  testWidgets('stale cached feed stays interactive with a discreet notice', (
    tester,
  ) async {
    await _pump(
      tester,
      () => Stream.value(_data(status: 'SCHEDULED', stale: true)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Mostrando datos guardados.'), findsOneWidget);
    expect(find.text('Sin conexión.'), findsNothing);
    expect(find.byKey(const ValueKey('match-row-match')), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Próximos'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('match-row-match')), findsOneWidget);
  });

  testWidgets('stale empty cache is not presented as a confirmed empty day', (
    tester,
  ) async {
    await _pump(tester, () => Stream.value(_data(stale: true)));
    await tester.pumpAndSettle();

    expect(
      find.text('No pudimos confirmar los partidos de este día.'),
      findsOneWidget,
    );
    expect(find.text('No hay partidos para este día.'), findsNothing);
    expect(find.text('Sin conexión.'), findsNothing);
    expect(find.text('Reintentar'), findsOneWidget);
  });

  testWidgets('future empty date can return to today without blocking dates', (
    tester,
  ) async {
    await _pump(tester, () => Stream.value(_data()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('MAÑANA'));
    await tester.pumpAndSettle();

    expect(find.text('No hay partidos para este día.'), findsOneWidget);
    expect(find.text('Volver a Hoy'), findsOneWidget);
    await tester.tap(find.text('Volver a Hoy'));
    await tester.pumpAndSettle();
    expect(find.text('HOY'), findsOneWidget);
    expect(find.text('Volver a Hoy'), findsNothing);
  });

  for (final width in [320.0, 360.0, 390.0]) {
    testWidgets('empty state has no overflow at ${width.toInt()}px', (
      tester,
    ) async {
      await _pump(tester, () => Stream.value(_data()), width: width);
      await tester.pumpAndSettle();
      expect(find.text('No hay partidos para este día.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('error state supports increased text scale without overflow', (
    tester,
  ) async {
    await _pump(
      tester,
      () => Stream<Snapshot>.error(StateError('server')),
      width: 320,
      textScale: 1.5,
    );
    await tester.pumpAndSettle();
    expect(find.text('No pudimos cargar los partidos.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

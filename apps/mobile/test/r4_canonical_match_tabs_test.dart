import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/matches/match_screen.dart';

import 'r3_match_center_regressions_test.dart' show fixture;

Future<StreamController<Snapshot>> open(
  WidgetTester tester,
  String status,
) async {
  final stream = StreamController<Snapshot>();
  final db = AppDatabase(NativeDatabase.memory());
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) => h.reject(DioException(requestOptions: o)),
      ),
    );
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(ApiRepository(dio, db)),
      matchContextSnapshotProvider.overrideWith((ref, id) => stream.stream),
      matchDetailProvider.overrideWith(
        (ref, id) => Stream.value(
          MatchDetail({
            'matchId': id,
            'available': true,
            'pending': false,
            'home': {},
            'away': {},
            'statistics': [],
          }),
        ),
      ),
      matchPreviewProvider.overrideWith(
        (ref, id) async => throw StateError('fixture no preview'),
      ),
      followsProvider.overrideWith((ref) => Stream.value({})),
      liveMatchUpdatesProvider.overrideWith((ref) => Stream.value({})),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await stream.close();
    dio.close();
    await tester.runAsync(db.close);
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: MatchScreen(id: 'fb_match', initialData: fixture(status)),
      ),
    ),
  );
  stream.add(fixture(status));
  await tester.pumpAndSettle();
  return stream;
}

List<String> labels(WidgetTester t) => t
    .widget<TabBar>(find.byType(TabBar))
    .tabs
    .map((w) => (w as Tab).text!)
    .toList();
String selected(WidgetTester t) {
  final b = t.widget<TabBar>(find.byType(TabBar));
  return (b.tabs[b.controller!.index] as Tab).text!;
}

Future<void> tap(WidgetTester t, String s) async {
  await t.ensureVisible(find.text(s).first);
  await t.tap(find.text(s).first);
  // The live field deliberately animates continuously.
  await t.pump(const Duration(milliseconds: 500));
  await t.pump();
}

void main() {
  testWidgets(
    'R4 canonical cancellation during tab animation never leaves a stale page',
    (t) async {
      final states = await open(t, 'LIVE');
      await t.ensureVisible(find.text('En vivo').first);
      await t.tap(find.text('En vivo').first);
      await t.pump(const Duration(milliseconds: 10));
      states.add(fixture('CANCELLED'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      expect(selected(t), 'Hechos');
      expect(labels(t), isNot(contains('En vivo')));
      expect(t.takeException(), isNull);
    },
  );
  for (final status in [
    'SCHEDULED',
    'NOT_STARTED',
    'LIVE',
    'HALFTIME',
    'FINISHED',
    'VERIFIED',
    'POSTPONED',
    'CANCELLED',
  ]) {
    testWidgets(
      'R4 canonical tabs $status ignore future kickoff and retained stats',
      (t) async {
        await open(t, status);
        final live = ['LIVE', 'HALFTIME'].contains(status);
        final finalState = ['FINISHED', 'VERIFIED'].contains(status);
        expect(labels(t).contains('En vivo'), live);
        expect(labels(t).contains('Estadísticas'), live || finalState);
        for (final name in ['Alineación', 'Tabla', 'Cara a cara']) {
          expect(labels(t), contains(name));
        }
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'R4 state transitions keep section and safely remove selected tab',
    (t) async {
      final states = await open(t, 'SCHEDULED');
      await tap(t, 'Cara a cara');
      states.add(fixture('LIVE'));
      await t.pumpAndSettle();
      expect(selected(t), 'Cara a cara');
      await tap(t, 'En vivo');
      states.add(fixture('FINISHED'));
      await t.pumpAndSettle();
      expect(selected(t), 'Hechos');
      expect(labels(t), isNot(contains('En vivo')));
      await tap(t, 'Estadísticas');
      states.add(fixture('LIVE'));
      await t.pumpAndSettle();
      expect(selected(t), 'Estadísticas');
      states.add(fixture('POSTPONED'));
      await t.pumpAndSettle();
      expect(selected(t), 'Hechos');
      states.add(fixture('NOT_STARTED'));
      await t.pumpAndSettle();
      expect(selected(t), 'Previa');
      expect(t.takeException(), isNull);
    },
  );
}

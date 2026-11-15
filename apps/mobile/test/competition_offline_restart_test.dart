import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/features/entities/entity_screen.dart';

const _id = 'fb_competition_offline';
Map<String, dynamic> _catalog() => {
  'schemaVersion': 1,
  'demo': false,
  'updatedAt': DateTime.now().toUtc().toIso8601String(),
  'competitions': [
    {'id': _id, 'name': 'Stored League', 'country': 'England'},
  ],
  'teams': [
    {'id': 'fb_team_a', 'name': 'Alpha', 'competitionId': _id},
    {'id': 'fb_team_z', 'name': 'Zulu', 'competitionId': _id},
  ],
  'players': [],
  'matches': [],
  'news': [],
  'transfers': [],
  'standings': [
    {
      'competitionId': _id,
      'rows': [
        {
          'teamId': 'fb_team_a',
          'played': 3,
          'won': 2,
          'drawn': 1,
          'lost': 0,
          'gf': 5,
          'ga': 1,
          'points': 7,
        },
        {
          'teamId': 'fb_team_z',
          'played': 3,
          'won': 1,
          'drawn': 0,
          'lost': 2,
          'gf': 2,
          'ga': 4,
          'points': 3,
        },
      ],
    },
  ],
};

Dio _client({bool online = false, void Function()? requested}) =>
    Dio(BaseOptions(baseUrl: 'https://fixture.invalid'))
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requested?.call();
            if (online) {
              handler.resolve(
                Response(
                  requestOptions: request,
                  statusCode: 200,
                  data: _catalog(),
                ),
              );
            } else {
              handler.reject(
                DioException(
                  requestOptions: request,
                  type: DioExceptionType.connectionError,
                ),
              );
            }
          },
        ),
      );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('competition-offline-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  Future<void> settleRequests(WidgetTester tester) async {
    // Dio/SQLite complete on the real event loop; the bounded repository
    // retry delay uses the widget test's fake clock.
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(milliseconds: 350));
    }
  }

  Future<void> seed(File file) async {
    final db = AppDatabase(NativeDatabase(file));
    final dio = _client(online: true);
    try {
      final repo = ApiRepository(dio, db);
      await repo.loadEntity('competition', _id);
      await repo.settleBackground();
    } finally {
      dio.close();
      await db.close();
    }
  }

  test(
    'competition and exact standings survive a new SQLite connection offline',
    () async {
      final file = File('${directory.path}/sports.sqlite');
      await seed(file);
      final db = AppDatabase(NativeDatabase(file));
      final dio = _client();
      try {
        final repo = ApiRepository(dio, db);
        final first = await repo.watchPublicEntity('competition', _id).first;
        expect(first.stale, isTrue);
        expect(first.competition(_id)?.name, 'Stored League');
        expect(first.standings, _catalog()['standings']);
        final answer = await repo.loadEntity('competition', _id);
        expect(answer.standings, first.standings);
        expect(answer.stale, isTrue);
        expect(
          await db.readPublicSnapshot('public:entity:competition:$_id'),
          isNotNull,
        );
        await expectLater(
          repo.loadEntity('competition', 'fb_competition_unknown'),
          throwsA(isA<DioException>()),
        );
      } finally {
        dio.close();
        await db.close();
      }
    },
  );

  testWidgets(
    'uncached competition stops loading and never automatically retries',
    (tester) async {
      late AppDatabase db;
      await tester.runAsync(() async {
        db = AppDatabase(NativeDatabase.memory());
        await db.customSelect('select 1').get();
      });
      var calls = 0;
      final dio = _client(requested: () => calls++);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          repositoryProvider.overrideWithValue(ApiRepository(dio, db)),
          followsProvider.overrideWith((ref) => Stream.value(<String>{})),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        container.dispose();
        dio.close();
        await tester.runAsync(db.close);
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: EntityScreen(type: 'competition', id: _id),
          ),
        ),
      );
      await settleRequests(tester);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('No pudimos cargar este perfil'), findsOneWidget);
      expect(find.text('Sin conexión'), findsOneWidget);
      final settledCalls = calls;
      await tester.pump(const Duration(minutes: 2));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(calls, settledCalls);
      expect(calls, lessThanOrEqualTo(2));
      await tester.tap(find.text('Reintentar'));
      await settleRequests(tester);
      expect(calls, greaterThan(settledCalls));
    },
  );

  testWidgets(
    'cached competition paints its table after SQLite reopen without a network',
    (tester) async {
      final file = File('${directory.path}/screen.sqlite');
      late AppDatabase db;
      await tester.runAsync(() async {
        await seed(file);
        db = AppDatabase(NativeDatabase(file));
        await db.customSelect('select 1').get();
      });
      final dio = _client();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          repositoryProvider.overrideWithValue(ApiRepository(dio, db)),
          followsProvider.overrideWith((ref) => Stream.value(<String>{})),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        container.dispose();
        dio.close();
        await tester.runAsync(db.close);
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: EntityScreen(type: 'competition', id: _id),
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await tester.pumpAndSettle();
      expect(find.text('Stored League'), findsWidgets);
      expect(
        find.byWidgetPredicate(
          (w) => w is Banner && w.message == 'Datos guardados',
        ),
        findsNothing,
      );
      await tester.tap(find.text('Tabla'));
      await tester.pumpAndSettle();
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Zulu'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  const stage = String.fromEnvironment('FUTBEAT_COMPETITION_RESTART_STAGE');
  const path = String.fromEnvironment('FUTBEAT_COMPETITION_RESTART_FILE');
  test(
    'separate OS process restores competition and standings offline',
    () async {
      stdout.writeln('COMPETITION_STAGE=$stage TEST_PROCESS_PID=$pid');
      final file = File(path);
      if (stage == 'seed') {
        expect(file.existsSync(), isFalse);
        await seed(file);
        return;
      }
      final db = AppDatabase(NativeDatabase(file));
      final dio = _client();
      try {
        final answer = await ApiRepository(
          dio,
          db,
        ).watchPublicEntity('competition', _id).first;
        expect(answer.stale, isTrue);
        expect(answer.competition(_id)?.name, 'Stored League');
        expect(
          jsonEncode(answer.standings),
          jsonEncode(_catalog()['standings']),
        );
      } finally {
        dio.close();
        await db.close();
      }
    },
    skip: stage.isEmpty || path.isEmpty,
  );
}

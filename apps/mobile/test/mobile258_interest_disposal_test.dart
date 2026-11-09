import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/push.dart';

class _DelayedInterestDatabase extends AppDatabase {
  _DelayedInterestDatabase() : super(NativeDatabase.memory());
  final gate = Completer<void>();
  int writes = 0;

  @override
  Future<void> touchInterest(
    String type,
    String id, {
    Duration ttl = const Duration(minutes: 30),
  }) {
    writes++;
    return gate.future;
  }
}

void main() {
  testWidgets('queued interest after disposal skips both providers', (
    tester,
  ) async {
    late WidgetRef retainedRef;
    var reads = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWith((ref) {
            reads++;
            throw StateError('Disposed route must not read the database');
          }),
        ],
        child: Consumer(
          builder: (_, ref, _) {
            retainedRef = ref;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    await recordTemporaryInterest(retainedRef, 'match', 'fb_match_old258');
    expect(reads, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'leaving a screen during its local interest write never reads a disposed WidgetRef',
    (tester) async {
      final db = _DelayedInterestDatabase();
      var accountReads = 0;
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          pushServiceProvider.overrideWith((ref) {
            accountReads++;
            throw StateError(
              'No account provider should be created after navigation',
            );
          }),
        ],
      );
      Future<void>? pending;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Consumer(
              builder: (_, ref, _) => Scaffold(
                body: FilledButton(
                  onPressed: () => pending = recordTemporaryInterest(
                    ref,
                    'match',
                    'fb_match_dispose258',
                  ),
                  child: const Text('Abrir partido'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Abrir partido'));
      expect(db.writes, 1);
      await tester.pumpWidget(const SizedBox());
      final completed = expectLater(pending, completes);
      db.gate.complete();
      await tester.pump();
      await completed;
      expect(accountReads, 0);
      expect(tester.takeException(), isNull);
      container.dispose();
      await tester.runAsync(db.close);
    },
  );
}

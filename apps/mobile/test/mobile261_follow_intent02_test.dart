import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/entity_media.dart';
import 'package:futbeat/core/providers.dart';

void main() {
  for (final type in ['team', 'competition', 'player', 'match']) {
    test(
      '$type: ownership intent completes before alias-aware follow mutation',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        final redirects = EntityRedirectMemory()
          ..absorb({
            'fb_alias': 'fb_middle',
            'fb_middle': 'fb_canonical',
            'fb_other': 'fb_unrelated',
          });
        addTearDown(db.close);
        addTearDown(redirects.dispose);
        final entered = Completer<void>();
        final release = Completer<void>();
        Set<String>? claimed;
        final operation = toggleFollow(
          db,
          redirects,
          type,
          'fb_alias',
          onIntent: (keys) async {
            claimed = keys;
            entered.complete();
            await release.future;
          },
        );
        await entered.future;
        expect(
          claimed,
          type == 'match'
              ? {'match:fb_alias'}
              : {'$type:fb_alias', '$type:fb_middle', '$type:fb_canonical'},
        );
        expect(await db.watchFollows().first, isEmpty);
        release.complete();
        await operation;
        expect(await db.watchFollows().first, {
          type == 'match' ? 'match:fb_alias' : '$type:fb_canonical',
        });
      },
    );
  }
  test('intent failure does not mutate follows; callback-free toggle stays compatible', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final redirects = EntityRedirectMemory();
    addTearDown(db.close);
    addTearDown(redirects.dispose);
    await expectLater(
      toggleFollow(
        db,
        redirects,
        'team',
        'fb_team',
        onIntent: (keys) async {
          throw StateError('ownership persistence failed');
        },
      ),
      throwsStateError,
    );
    expect(await db.watchFollows().first, isEmpty);
    await toggleFollow(db, redirects, 'team', 'fb_team');
    expect(await db.watchFollows().first, {'team:fb_team'});
    await toggleFollow(db, redirects, 'team', 'fb_team');
    expect(await db.watchFollows().first, isEmpty);
  });
}

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';

void main() {
  test(
    'FB-US-036/037/038: follows survive reopen and toggle independently',
    () async {
      final directory = await Directory.systemTemp.createTemp('futbeat-test-');
      final file = File('${directory.path}/follows.sqlite');
      var db = AppDatabase(NativeDatabase(file));
      try {
        await db.toggle('team', 'fb_team_sap');
        await db.toggle('player', 'fb_player_torres');
        await db.close();
        db = AppDatabase(NativeDatabase(file));
        expect(await db.watchFollows().first, {
          'team:fb_team_sap',
          'player:fb_player_torres',
        });
        await db.toggle('team', 'fb_team_sap');
        expect(await db.watchFollows().first, {'player:fb_player_torres'});
      } finally {
        await db.close();
        await directory.delete(recursive: true);
      }
    },
  );
}

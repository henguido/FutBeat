import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/main.dart';
import 'package:futbeat/core/models.dart';

import 'flow_test.dart' show openApp, TestRepository;
import 'support/platform_goldens.dart';

/// This existing baseline depicts a RECENT live observation. Its historic
/// demo fixture has no observation timestamp. Make that test assumption
/// explicit without changing any golden reference. Stale/unknown LIVE is
/// covered separately in mobile239_resilience_test and its captured image.
class _RecentVisualRepository extends TestRepository {
  Snapshot recent(Snapshot data) {
    for (final match in data.matches.where((match) => match.isLive)) {
      match.json['liveObservedAt'] = DateTime.now().toUtc().toIso8601String();
    }
    return data;
  }

  @override
  Future<Snapshot> load() async => recent(await super.load());
  @override
  Future<Snapshot> loadDate(DateTime date) async =>
      recent(await super.loadDate(date));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('FutBeatRoboto')
      ..addFont(rootBundle.load('assets/fonts/roboto-regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/roboto-bold.ttf'));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  for (final (name, route) in [
    ('matches', '/matches'),
    ('match', '/match/fb_match_clasico'),
    ('competition', '/competition/fb_comp_cr'),
    ('team', '/team/fb_team_sap'),
    ('explore', '/explore'),
    ('player', '/player/fb_player_torres'),
  ]) {
    testWidgets('Visual review: $name', (tester) async {
      await openApp(
        tester,
        route: route,
        repository: _RecentVisualRepository(),
      );
      await expectLater(
        find.byType(FutBeatApp),
        matchesPlatformGolden('goldens/$name.png'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pump();
    }, tags: 'golden');
  }
}

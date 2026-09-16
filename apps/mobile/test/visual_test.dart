import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/main.dart';

import 'flow_test.dart' show openApp;

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
    ('explore', '/explore'),
  ]) {
    testWidgets('Visual review: $name', (tester) async {
      await openApp(tester, route: route);
      await expectLater(
        find.byType(FutBeatApp),
        matchesGoldenFile('goldens/$name.png'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pump();
    });
  }
}

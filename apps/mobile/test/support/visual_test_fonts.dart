import 'package:flutter/services.dart';

// Use the same bundled family and weight files as the application, rather than
// Ahem/system fonts, in both screenshot and non-pixel overflow regressions.
Future<void>? _loaded;
Future<void> loadFutBeatVisualFonts() => _loaded ??= _load();

Future<void> _load() async {
  await (FontLoader('FutBeatRoboto')
        ..addFont(rootBundle.load('assets/fonts/roboto-regular.ttf'))
        ..addFont(rootBundle.load('assets/fonts/roboto-bold.ttf')))
      .load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
}

// The native Firebase mock deliberately exercises the installed SDK boundary.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/push.dart';

class _NativeFirebase extends FirebasePlatform {
  final release = Completer<void>();
  final initialized = <FirebaseAppPlatform>[];
  int calls = 0;
  bool active = false;
  bool failNext = false;
  @override
  List<FirebaseAppPlatform> get apps => initialized;
  @override
  Future<FirebaseAppPlatform> initializeApp({
    String? name,
    FirebaseOptions? options,
  }) async {
    calls++;
    if (active) throw FirebaseException(plugin: 'core', code: 'duplicate-app');
    active = true;
    try {
      await release.future;
      if (failNext) {
        failNext = false;
        throw FirebaseException(plugin: 'core', code: 'native-unavailable');
      }
      final app = FirebaseAppPlatform(defaultFirebaseAppName, options!);
      initialized.add(app);
      return app;
    } finally {
      active = false;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FirebasePlatform previous;
  late _NativeFirebase native;
  setUp(() {
    previous = FirebasePlatform.instance;
    FirebasePlatform.instance = native = _NativeFirebase();
    Firebase.delegatePackingProperty = native;
  });
  tearDown(() {
    FirebasePlatform.instance = previous;
    Firebase.delegatePackingProperty = previous;
  });

  test(
    'foreground, opened and initial consumers share native initialization',
    () async {
      final pending = Future.wait(
        [
          ensureFirebase(),
          ensureFirebase(),
          ensureFirebase(),
        ].map((f) => f.then<Object?>((_) => null, onError: (Object e) => e)),
      );
      native.release.complete();
      final outcomes = await pending;
      expect(
        native.calls,
        1,
        reason: 'duplicate native initialization ends push streams',
      );
      expect(outcomes, everyElement(isNull));
      await ensureFirebase();
      expect(native.calls, 1);
    },
  );

  test('a failed native initialization permits a later shared retry', () async {
    native.failNext = true;
    final first = ensureFirebase();
    final failed = expectLater(first, throwsA(isA<FirebaseException>()));
    native.release.complete();
    await failed;
    await Future.wait([ensureFirebase(), ensureFirebase()]);
    expect(native.calls, 2);
  });
}

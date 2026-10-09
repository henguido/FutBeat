import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/core/database.dart';
import 'package:futbeat/core/interests.dart';
import 'package:futbeat/core/live_realtime.dart';
import 'package:futbeat/core/models.dart';
import 'package:futbeat/core/password_reset_links.dart';
import 'package:futbeat/core/providers.dart';
import 'package:futbeat/core/push.dart';
import 'package:futbeat/main.dart';
import 'package:go_router/go_router.dart';

import 'flow_test.dart' show TestRepository;

class _Tokens implements PushTokenSource {
  @override
  Future<String?> currentToken() async => null;

  @override
  Future<String?> requestToken() async => null;

  @override
  Stream<String> get rotations => const Stream.empty();
}

/// Records redemptions; a token_hash of "bad" is an expired link.
class _ResetService extends PushService {
  _ResetService(AppDatabase db)
    : super(
        const LiveRealtimeConfig(
          supabaseUrl: 'https://supabase.test',
          publicKey: 'publishable-test-key',
        ),
        db,
        _Tokens(),
      );

  final redeemed = <String>[];

  @override
  Future<void> beginPasswordRecovery(Uri link) async {
    final token = link.queryParameters['token_hash'] ?? '';
    redeemed.add(token);
    if (token == 'bad') throw const RecoveryLinkInvalid('rejected');
  }

  @override
  Future<void> completePasswordRecovery(String newPassword) async {}
}

Uri _link(String token, {bool web = false}) => Uri.parse(
  web
      ? 'com.futbeat.futbeat://password-reset?token_hash=$token&type=recovery'
      : 'https://futbeat.com/auth/reset?token_hash=$token&type=recovery',
);

const _newPassword = 'Nueva contraseña';

/// /start, /onboarding and /matches like the app's router, without the
/// providers of the real screens.
GoRouter _router(String initial) => GoRouter(
  initialLocation: initial,
  routes: [
    GoRoute(
      path: '/start',
      builder: (_, _) => const Scaffold(body: Text('start')),
    ),
    GoRoute(
      path: '/onboarding',
      builder: (_, _) => const Scaffold(body: Text('onboarding')),
    ),
    GoRoute(
      path: '/matches',
      builder: (_, _) => const Scaffold(body: Text('matches')),
    ),
  ],
);

void main() {
  late AppDatabase db;
  late _ResetService service;
  final messenger = GlobalKey<ScaffoldMessengerState>();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    service = _ResetService(db);
  });

  tearDown(() async {
    service.dispose();
    await db.close();
  });

  PasswordResetLinkQueue queueFor(GoRouter router) => PasswordResetLinkQueue(
    router: router,
    handle: (link, navigator) => handlePasswordResetLink(
      link,
      service: service,
      navigator: navigator,
      messenger: messenger.currentState,
    ),
  );

  Future<void> mount(WidgetTester tester, GoRouter router) async {
    await tester.pumpWidget(
      MaterialApp.router(routerConfig: router, scaffoldMessengerKey: messenger),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'root cause: a screen pushed over /start is removed by the startup go() '
    'after the one-time token was spent',
    (tester) async {
      final router = _router('/start');
      addTearDown(router.dispose);
      await mount(tester, router);
      // What b45bf86 did: redeem at once with the Navigator of that moment.
      unawaited(
        handlePasswordResetLink(
          _link('one'),
          service: service,
          navigator: router.routerDelegate.navigatorKey.currentState,
          messenger: messenger.currentState,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(_newPassword), findsWidgets);
      router.go('/matches'); // StartupGate once the preference loads.
      await tester.pumpAndSettle();
      expect(service.redeemed, ['one']);
      expect(find.text(_newPassword), findsNothing);
      // And with no Navigator yet the token is spent without any screen.
      await handlePasswordResetLink(
        _link('two'),
        service: service,
        navigator: null,
        messenger: null,
      );
      expect(service.redeemed, ['one', 'two']);
      expect(find.text(_newPassword), findsNothing);
    },
  );

  testWidgets('cold start: a link before the Navigator exists waits for the '
      'router to leave /start, is redeemed once and its screen stays', (
    tester,
  ) async {
    final router = _router('/start');
    addTearDown(router.dispose);
    final queue = queueFor(router);
    addTearDown(queue.dispose);
    queue.add(_link('cold'));
    await tester.pump();
    expect(service.redeemed, isEmpty, reason: 'no Navigator yet');
    await mount(tester, router);
    expect(service.redeemed, isEmpty, reason: 'still on /start');
    router.go('/matches');
    await tester.pumpAndSettle();
    expect(service.redeemed, ['cold']);
    expect(find.text(_newPassword), findsWidgets);
  });

  testWidgets('cold start into onboarding is not blocked (fresh install)', (
    tester,
  ) async {
    final router = _router('/start');
    addTearDown(router.dispose);
    final queue = queueFor(router);
    addTearDown(queue.dispose);
    await mount(tester, router);
    queue.add(_link('fresh', web: true));
    await tester.pump();
    expect(service.redeemed, isEmpty);
    router.go('/onboarding');
    await tester.pumpAndSettle();
    expect(service.redeemed, ['fresh']);
    expect(find.text(_newPassword), findsWidgets);
  });

  testWidgets('background: an app already in the shell opens the screen at '
      'once', (tester) async {
    final router = _router('/matches');
    addTearDown(router.dispose);
    final queue = queueFor(router);
    addTearDown(queue.dispose);
    await mount(tester, router);
    queue.add(_link('warm'));
    await tester.pumpAndSettle();
    expect(service.redeemed, ['warm']);
    expect(find.text(_newPassword), findsWidgets);
  });

  testWidgets('duplicate link: redeemed once, one screen, also when Android '
      'delivers it again later', (tester) async {
    final router = _router('/matches');
    addTearDown(router.dispose);
    final queue = queueFor(router);
    addTearDown(queue.dispose);
    await mount(tester, router);
    queue
      ..add(_link('dup'))
      ..add(_link('dup'));
    await tester.pumpAndSettle();
    expect(service.redeemed, ['dup']);
    expect(find.byType(BackButton), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    queue.add(_link('dup'));
    await tester.pumpAndSettle();
    expect(service.redeemed, ['dup']);
    expect(find.text(_newPassword), findsNothing);
  });

  testWidgets('invalid token: one message, no screen, the next link still '
      'works', (tester) async {
    final router = _router('/start');
    addTearDown(router.dispose);
    final queue = queueFor(router);
    addTearDown(queue.dispose);
    queue
      ..add(_link('bad'))
      ..add(_link('good'));
    await mount(tester, router);
    router.go('/matches');
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('El enlace ya no es válido. Pide uno nuevo.'), findsOne);
    await tester.pumpAndSettle();
    expect(service.redeemed, ['bad', 'good']);
    expect(find.text(_newPassword), findsWidgets);
  });

  testWidgets('OAuth callbacks and foreign links are never queued or '
      'redeemed', (tester) async {
    final router = _router('/matches');
    addTearDown(router.dispose);
    final queue = queueFor(router);
    addTearDown(queue.dispose);
    await mount(tester, router);
    for (final other in [
      'com.futbeat.futbeat://login-callback?code=x',
      'https://evil.example/auth/reset?token_hash=x&type=recovery',
      'https://futbeat.com/privacy',
    ]) {
      queue.add(Uri.parse(other));
    }
    await tester.pumpAndSettle();
    expect(service.redeemed, isEmpty);
    expect(find.text(_newPassword), findsNothing);
  });

  testWidgets('app: the initial link of a cold start opens the screen after '
      'StartupGate routes, not before', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = createRouter(initialLocation: '/start');
    addTearDown(router.dispose);
    final preference = StreamController<CountryPreference>();
    addTearDown(preference.close);
    final links = StreamController<Uri>()..add(_link('app'));
    addTearDown(links.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repositoryProvider.overrideWithValue(TestRepository()),
          matchDetailProvider.overrideWith(
            (ref, id) => Stream.value(MatchDetail.empty(id)),
          ),
          databaseProvider.overrideWithValue(db),
          pushServiceProvider.overrideWithValue(service),
          preferenceProvider.overrideWith((ref) => preference.stream),
          followsProvider.overrideWith((ref) => Stream.value(<String>{})),
          temporaryInterestsProvider.overrideWith(
            (ref) => Stream.value(<String>{}),
          ),
        ],
        child: FutBeatApp(router: router, resetLinks: links.stream),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(service.redeemed, isEmpty, reason: 'StartupGate still loading');
    preference.add(
      const CountryPreference(
        detectedCountry: 'CR',
        selectedCountry: null,
        bootstrapDismissed: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(service.redeemed, ['app']);
    expect(find.text(_newPassword), findsWidgets);
  });
}

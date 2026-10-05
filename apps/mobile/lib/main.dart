import 'dart:async';
import 'dart:io' show Platform;

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/ads.dart';
import 'core/billing.dart';
import 'core/database.dart';
import 'core/entity_media.dart';
import 'core/models.dart';
import 'core/providers.dart';
import 'core/theme.dart';
import 'core/push.dart';
import 'core/push_messages.dart';
import 'core/interests.dart';
import 'features/profile/profile_screen.dart';
import 'features/matches/matches_screen.dart';
import 'features/matches/match_screen.dart';
import 'features/entities/entity_screen.dart';
import 'features/explore/explore_screen.dart';
import 'features/favorites/favorites_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/profile/password_reset_sheet.dart';
import 'shared/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadDeviceRegion();
  runApp(const ProviderScope(child: FutBeatApp()));
}

Future<CountryPreference> refreshCountryForLocales(
  AppDatabase database,
  List<Locale>? locales,
) {
  final detected = deviceCountry(
    locales != null && locales.isNotEmpty ? locales.first.countryCode : null,
  );
  return refreshDetectedCountry(database, detected);
}

/// The reset email's https://futbeat.com/auth/reset App Link (or the web
/// fallback's com.futbeat.futbeat://password-reset): redeems the one-time
/// token and opens [NewPasswordScreen] on [navigator]. The token never
/// becomes a route, so it is not kept in navigation. Other links are
/// ignored (OAuth callbacks go to flutter_web_auth_2).
Future<void> handlePasswordResetLink(
  Uri link, {
  required PushService service,
  required NavigatorState? navigator,
  required ScaffoldMessengerState? messenger,
  Future<void> Function()? onSignedIn,
}) async {
  if (!PushService.isPasswordResetLink(link)) return;
  // Host and path only: the one-time token is never logged.
  debugPrint('FutBeat reset link: ${link.host}${link.path}');
  void say(String text) =>
      messenger?.showSnackBar(SnackBar(content: Text(text)));
  try {
    await service.beginPasswordRecovery(link);
  } on RecoveryLinkInvalid catch (error) {
    debugPrint('FutBeat reset link invalid: ${error.reason}');
    say(
      error.reason == 'missing_token'
          ? 'Ese enlace está incompleto. Pide uno nuevo.'
          : 'El enlace ya no es válido. Pide uno nuevo.',
    );
    return;
  } catch (_) {
    say('No se pudo abrir el enlace. Inténtalo de nuevo.');
    return;
  }
  if (navigator == null) return;
  final changed = await navigator.push<bool>(
    MaterialPageRoute(builder: (_) => NewPasswordScreen(service: service)),
  );
  if (changed != true) return;
  say('Contraseña actualizada. Sesión iniciada.');
  await onSignedIn?.call();
}

GoRouter createRouter({String initialLocation = '/start'}) => GoRouter(
  initialLocation: initialLocation,
  errorBuilder: (context, state) => Scaffold(
    appBar: AppBar(title: const Text('FutBeat')),
    body: Center(
      child: TextButton(
        onPressed: () => context.go('/matches'),
        child: const Text('Página no encontrada · Volver a partidos'),
      ),
    ),
  ),
  routes: [
    GoRoute(path: '/start', builder: (_, state) => const StartupGate()),
    GoRoute(
      path: '/onboarding',
      builder: (_, state) => OnboardingScreen(
        reentry: state.uri.queryParameters['reentry'] == '1',
      ),
    ),
    ShellRoute(
      builder: (context, state, child) =>
          AppShell(location: state.uri.path, child: child),
      routes: [
        GoRoute(path: '/matches', builder: (_, state) => const MatchesScreen()),
        GoRoute(
          path: '/news',
          builder: (_, state) => const SectionScreen(
            title: 'Noticias',
            child: EmptyState(
              'El fútbol también se cuenta',
              'Todavía no hay noticias disponibles. Las fuentes de noticias se conectarán en un próximo incremento.',
              icon: Icons.article_outlined,
            ),
          ),
        ),
        GoRoute(path: '/explore', builder: (_, state) => const ExploreScreen()),
        GoRoute(
          path: '/favorites',
          builder: (_, state) => const FavoritesScreen(),
        ),
        GoRoute(path: '/profile', builder: (_, state) => const ProfileScreen()),
        GoRoute(
          path: '/match/:id',
          builder: (_, state) {
            final extra = state.extra;
            return MatchScreen(
              id: state.pathParameters['id']!,
              initialData: extra is Snapshot ? extra : null,
            );
          },
        ),
        for (final type in ['team', 'player', 'competition'])
          GoRoute(
            path: '/$type/:id',
            builder: (_, state) => EntityScreen(
              type: type,
              id: state.pathParameters['id']!,
              // Opened from a match: that competition + season (#161).
              competitionId: state.uri.queryParameters['competitionId'],
              season: state.uri.queryParameters['season'],
            ),
          ),
      ],
    ),
  ],
);

class StartupGate extends ConsumerWidget {
  const StartupGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preference = ref.watch(preferenceProvider);
    final value = preference.asData?.value;
    if (value != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        context.go(value.bootstrapDismissed ? '/matches' : '/onboarding');
      });
    }
    if (preference.hasError) {
      return Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () => context.go('/matches'),
            child: const Text('Continuar a Partidos'),
          ),
        ),
      );
    }
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class FutBeatApp extends ConsumerStatefulWidget {
  const FutBeatApp({super.key, this.router});
  final GoRouter? router;
  @override
  ConsumerState<FutBeatApp> createState() => _FutBeatAppState();
}

class _FutBeatAppState extends ConsumerState<FutBeatApp>
    with WidgetsBindingObserver {
  late final GoRouter router = widget.router ?? createRouter();
  final messenger = GlobalKey<ScaffoldMessengerState>();
  PushMessageRouter? pushMessages;
  bool followPromptChecked = false;
  StreamSubscription<Uri>? links;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Password-reset links (the initial one included), Android only.
    if (Platform.isAndroid) {
      links = AppLinks().uriLinkStream.listen(
        (link) => unawaited(
          handlePasswordResetLink(
            link,
            service: ref.read(pushServiceProvider),
            navigator: router.routerDelegate.navigatorKey.currentState,
            messenger: messenger.currentState,
            onSignedIn: _afterRecovery,
          ),
        ),
        onError: (_) {},
      );
    }
    // Null unless the build has the push flags: nothing runs otherwise.
    final source = ref.read(pushMessageSourceProvider);
    if (source != null) {
      unawaited(ensureAndroidNotificationChannel());
      pushMessages = PushMessageRouter(
        source: source,
        router: router,
        messenger: messenger,
      )..start();
    }
  }

  /// After a password reset the account is signed in: close the sheets
  /// that requested the link and land on Partidos (an existing account is
  /// set up; a first-run onboarding is completed by it).
  Future<void> _afterRecovery() async {
    final navigator = router.routerDelegate.navigatorKey.currentState;
    navigator?.popUntil((route) => route is! PopupRoute);
    await ref.read(databaseProvider).markBootstrapDismissed();
    unawaited(const SecureOnboardingProgressStore().clear());
    router.go('/matches');
  }

  /// The first follow added in this session offers notifications once.
  void _onFollows(
    AsyncValue<Set<String>>? previous,
    AsyncValue<Set<String>> next,
  ) {
    if (followPromptChecked) return;
    if (!followAdded(previous?.asData?.value, next.asData?.value)) return;
    followPromptChecked = true;
    final context = router.routerDelegate.navigatorKey.currentContext;
    if (context == null) return;
    unawaited(maybeOfferNotifications(context, ref.read(pushServiceProvider)));
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    ref.invalidate(detectedCountryProvider);
    unawaited(_refreshCountry(locales));
  }

  Future<void> _refreshCountry(List<Locale>? locales) async {
    final database = ref.read(databaseProvider);
    final service = ref.read(pushServiceProvider);
    try {
      final preference = await refreshCountryForLocales(database, locales);
      await service.markDetectedCountryDirty();
      if (service.authenticated) {
        await service.syncCountries(
          preference.detectedCountry,
          preference.selectedCountry,
          updateSelected: false,
        );
      }
      if (mounted) ref.invalidate(preferenceProvider);
    } catch (_) {
      // The next preference read retries; locale changes must not crash UI.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Retry a session refresh/merge that failed offline, without creating
    // the account service just for this.
    if (state == AppLifecycleState.resumed && ref.exists(pushServiceProvider)) {
      unawaited(ref.read(pushServiceProvider).resume());
    }
    // Play may have renewed, cancelled or expired Premium meanwhile.
    if (state == AppLifecycleState.resumed &&
        ref.exists(premiumBillingProvider)) {
      unawaited(ref.read(premiumBillingProvider.notifier).onResume());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    pushMessages?.dispose();
    unawaited(links?.cancel());
    if (widget.router == null) router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hourFormat =
        ref.watch(profileSettingsProvider).asData?.value.hourFormat ?? 'system';
    final media = ref.watch(entityMediaProvider);
    if (PushService.configured) ref.listen(followsProvider, _onFollows);

    return MaterialApp.router(
      locale: const Locale('es'),
      supportedLocales: const [Locale('es')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      title: 'FutBeat',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: messenger,
      theme: futbeatTheme(),
      builder: (context, child) {
        final query = MediaQuery.of(context);
        final use24HourClock = switch (hourFormat) {
          '24h' => true,
          '12h' => false,
          _ => query.alwaysUse24HourFormat,
        };
        return MediaQuery(
          data: query.copyWith(alwaysUse24HourFormat: use24HourClock),
          child: EntityMediaScope(
            memory: media,
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
      routerConfig: router,
    );
  }
}

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.location, required this.child});
  final String location;
  final Widget child;
  static const paths = [
    '/matches',
    '/news',
    '/explore',
    '/favorites',
    '/profile',
  ];

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  /// The tab the user is in. A detail screen pushed from a tab (team,
  /// player, match, ...) has no tab of its own and keeps this one
  /// highlighted; opened directly (deep link) it falls back to Partidos.
  int tab = 0;

  void _track() {
    final index = AppShell.paths.indexOf(widget.location);
    if (index >= 0) tab = index;
  }

  @override
  void initState() {
    super.initState();
    _track();
  }

  @override
  void didUpdateWidget(AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    _track();
  }

  @override
  Widget build(BuildContext context) {
    if (PushService.configured) ref.watch(pushServiceProvider);
    // Billing listens to purchases app-wide (completes and verifies them).
    if (ref.watch(billingGatewayProvider) != null) {
      ref.watch(premiumBillingProvider);
    }
    // Ads consent (Google UMP) once, at start, only for FREE users with ads.
    if (ref.watch(adsEligibleProvider)) ensureAdsConsent(ref);
    return Scaffold(
      body: widget.child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (index) => context.go(AppShell.paths[index]),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.sports_soccer),
            label: 'Partidos',
          ),
          NavigationDestination(
            icon: Icon(Icons.article_outlined),
            label: 'Noticias',
          ),
          NavigationDestination(icon: Icon(Icons.search), label: 'Explorar'),
          NavigationDestination(
            icon: Icon(Icons.star_border),
            label: 'Favoritos',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            label: 'Perfil',
          ),
        ],
      ),
    );
  }
}

class SectionScreen extends StatelessWidget {
  const SectionScreen({super.key, required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: ListView(padding: const EdgeInsets.all(20), children: [child]),
  );
}

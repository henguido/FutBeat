import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/models.dart';
import 'core/theme.dart';
import 'core/push.dart';
import 'features/profile/profile_screen.dart';
import 'features/matches/matches_screen.dart';
import 'features/matches/match_screen.dart';
import 'features/entities/entity_screen.dart';
import 'features/explore/explore_screen.dart';
import 'features/favorites/favorites_screen.dart';
import 'shared/widgets.dart';

void main() => runApp(const ProviderScope(child: FutBeatApp()));

GoRouter createRouter({String initialLocation = '/matches'}) => GoRouter(
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
            builder: (_, state) =>
                EntityScreen(type: type, id: state.pathParameters['id']!),
          ),
      ],
    ),
  ],
);

class FutBeatApp extends ConsumerStatefulWidget {
  const FutBeatApp({super.key, this.router});
  final GoRouter? router;
  @override
  ConsumerState<FutBeatApp> createState() => _FutBeatAppState();
}

class _FutBeatAppState extends ConsumerState<FutBeatApp> {
  late final GoRouter router = widget.router ?? createRouter();
  @override
  void dispose() {
    if (widget.router == null) router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hourFormat =
        ref.watch(profileSettingsProvider).asData?.value.hourFormat ?? 'system';

    return MaterialApp.router(
      locale: const Locale('es'),
      supportedLocales: const [Locale('es')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      title: 'FutBeat',
      debugShowCheckedModeBanner: false,
      theme: futbeatTheme(),
      builder: (context, child) {
        final media = MediaQuery.of(context);
        final use24HourClock = switch (hourFormat) {
          '24h' => true,
          '12h' => false,
          _ => media.alwaysUse24HourFormat,
        };
        return MediaQuery(
          data: media.copyWith(alwaysUse24HourFormat: use24HourClock),
          child: child ?? const SizedBox.shrink(),
        );
      },
      routerConfig: router,
    );
  }
}

class AppShell extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    if (PushService.configured) ref.watch(pushServiceProvider);
    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: paths.contains(location) ? paths.indexOf(location) : 0,
        onDestinationSelected: (index) => context.go(paths[index]),
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

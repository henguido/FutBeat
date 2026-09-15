import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/theme.dart';
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
              'Todavía no hay noticias disponibles en esta demostración. Las fuentes se conectarán en el siguiente incremento.',
              icon: Icons.article_outlined,
            ),
          ),
        ),
        GoRoute(path: '/explore', builder: (_, state) => const ExploreScreen()),
        GoRoute(
          path: '/favorites',
          builder: (_, state) => const FavoritesScreen(),
        ),
        GoRoute(
          path: '/profile',
          builder: (_, state) => const SectionScreen(
            title: 'Perfil',
            child: EmptyState(
              'Tu fútbol, a tu manera',
              'Estás usando FutBeat como invitado. Tus favoritos se guardan en este dispositivo. El acceso con cuenta y las notificaciones llegarán después.',
              icon: Icons.person_outline,
            ),
          ),
        ),
        GoRoute(
          path: '/match/:id',
          builder: (_, state) => MatchScreen(id: state.pathParameters['id']!),
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

class FutBeatApp extends StatefulWidget {
  const FutBeatApp({super.key, this.router});
  final GoRouter? router;
  @override
  State<FutBeatApp> createState() => _FutBeatAppState();
}

class _FutBeatAppState extends State<FutBeatApp> {
  late final GoRouter router = widget.router ?? createRouter();
  @override
  void dispose() {
    if (widget.router == null) router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    locale: const Locale('es'),
    supportedLocales: const [Locale('es')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    title: 'FutBeat',
    debugShowCheckedModeBanner: false,
    theme: futbeatTheme(),
    routerConfig: router,
  );
}

class AppShell extends StatelessWidget {
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
  Widget build(BuildContext context) => Scaffold(
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

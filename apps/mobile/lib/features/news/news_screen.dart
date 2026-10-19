import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../shared/widgets.dart';

enum NewsSection {
  forYou('Para ti'),
  latest('Últimas'),
  teams('Equipos seguidos'),
  players('Jugadores seguidos'),
  competitions('Competiciones'),
  transfers('Fichajes');

  const NewsSection(this.label);
  final String label;
}

bool _newsSubject(Json article, Set<String> follows, String kind) {
  final subjects = article['subjects'];
  if (subjects is! List) return false;
  return subjects.whereType<Map>().any((subject) {
    final type = subject['type']?.toString();
    final id = subject['id']?.toString();
    return type == kind && id != null && follows.contains('$type:$id');
  });
}

/// Filters only the articles returned by the existing news request.
/// Entity filters require explicit canonical subject tags from the feed.
List<Json> newsForSection(
  Iterable<Json> articles,
  NewsSection section, {
  Set<String> follows = const {},
  String query = '',
}) {
  final term = query.trim().toLowerCase();
  final shown = articles.where((article) {
    final title = article['title']?.toString().trim() ?? '';
    final source = article['sourceName']?.toString().trim() ?? '';
    final url = article['url']?.toString().trim() ?? '';
    final published = DateTime.tryParse(
      article['publishedAt']?.toString() ?? '',
    );
    if (title.isEmpty ||
        source.isEmpty ||
        !url.startsWith('https://') ||
        published == null) {
      return false;
    }
    if (term.isNotEmpty &&
        ![title, source, article['description']].whereType<Object>().any(
          (value) => value.toString().toLowerCase().contains(term),
        )) {
      return false;
    }
    return switch (section) {
      NewsSection.teams => _newsSubject(article, follows, 'team'),
      NewsSection.players => _newsSubject(article, follows, 'player'),
      NewsSection.competitions => _newsSubject(article, follows, 'competition'),
      NewsSection.transfers => article['category'] == 'TRANSFER',
      _ => true,
    };
  }).toList();
  if (section == NewsSection.latest) {
    shown.sort((a, b) {
      final left = DateTime.parse(a['publishedAt'].toString());
      final right = DateTime.parse(b['publishedAt'].toString());
      return right.compareTo(left);
    });
  }
  return shown;
}

/// Noticias: real stored articles (followed teams, players and competitions
/// first, then the country) and real roster changes. Nothing is invented:
/// with no articles the screen says so.
class NewsScreen extends ConsumerWidget {
  const NewsScreen({super.key});

  /// Roster changes shown before "Ver más".
  static const transfersPreview = 10;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(newsFeedProvider);
    final data = feed.asData?.value;
    final follows =
        ref.watch(followsProvider).asData?.value ?? const <String>{};
    Future<void> refresh() => ref.refresh(newsFeedProvider.future);

    final children = <Widget>[
      if (feed.isLoading && data == null)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 40),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (feed.hasError && data == null) ...[
        const EmptyState(
          'No pudimos cargar las noticias',
          'Revisa tu conexión e intenta de nuevo.',
          icon: Icons.cloud_off_outlined,
        ),
        Center(
          child: TextButton(
            onPressed: refresh,
            child: const Text('Reintentar'),
          ),
        ),
      ] else if (data != null) ...[
        if (data.news.isEmpty && data.transfers.isEmpty)
          const EmptyState(
            'Sin noticias disponibles',
            'Cuando haya noticias de tus equipos, jugadores o competiciones aparecerán aquí.',
            icon: Icons.article_outlined,
          ),
        if (data.news.isNotEmpty || data.transfers.isNotEmpty)
          NewsFeedContent(
            articles: data.news,
            transfers: data.transfers,
            follows: follows,
          ),
      ],
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Noticias',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          children: children,
        ),
      ),
    );
  }
}

/// Reusable local view: no additional API request or persistent storage.
class NewsFeedContent extends StatefulWidget {
  const NewsFeedContent({
    required this.articles,
    required this.transfers,
    this.follows = const {},
    super.key,
  });

  final List<Json> articles;
  final List<Json> transfers;
  final Set<String> follows;

  @override
  State<NewsFeedContent> createState() => _NewsFeedContentState();
}

class _NewsFeedContentState extends State<NewsFeedContent> {
  NewsSection selected = NewsSection.forYou;
  String query = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final articles = newsForSection(
      widget.articles,
      selected,
      follows: widget.follows,
      query: query,
    );
    final term = query.trim().toLowerCase();
    final transfers = widget.transfers.where((transfer) {
      if (term.isEmpty) return true;
      return [
        transfer['playerName'],
        transfer['fromTeamName'],
        transfer['toTeamName'],
      ].whereType<Object>().any(
        (value) => value.toString().toLowerCase().contains(term),
      );
    }).toList();
    final featured = selected == NewsSection.forYou
        ? articles.where((article) => article['featured'] == true).toList()
        : const <Json>[];
    final regular = selected == NewsSection.forYou
        ? articles.where((article) => article['featured'] != true).toList()
        : articles;
    final followKind = switch (selected) {
      NewsSection.teams => 'team:',
      NewsSection.players => 'player:',
      NewsSection.competitions => 'competition:',
      _ => null,
    };
    final noFollows =
        followKind != null &&
        !widget.follows.any((key) => key.startsWith(followKind));
    final emptyTitle = term.isNotEmpty
        ? 'Sin resultados para «${query.trim()}»'
        : noFollows
        ? switch (selected) {
            NewsSection.teams => 'Aún no sigues equipos',
            NewsSection.players => 'Aún no sigues jugadores',
            NewsSection.competitions => 'Aún no sigues competiciones',
            _ => 'Sin resultados para este filtro',
          }
        : selected == NewsSection.transfers
        ? 'Sin fichajes disponibles'
        : 'Sin resultados para este filtro';
    final emptyDescription = term.isNotEmpty
        ? 'Prueba otra búsqueda entre los artículos cargados.'
        : noFollows
        ? 'Sigue una entidad para ver aquí sus noticias, si están disponibles.'
        : 'No hay artículos cargados que cumplan este filtro.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('news-search'),
          controller: _searchController,
          onChanged: (value) => setState(() => query = value),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: 'Buscar en noticias cargadas',
            helperText: 'Búsqueda local; el feed carga hasta 40 artículos.',
            suffixIcon: query.isEmpty
                ? null
                : IconButton(
                    key: const ValueKey('news-search-clear'),
                    tooltip: 'Limpiar búsqueda',
                    onPressed: () {
                      _searchController.clear();
                      setState(() => query = '');
                    },
                    icon: const Icon(Icons.close),
                  ),
          ),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final section in NewsSection.values)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(section.label),
                    selected: selected == section,
                    onSelected: (_) => setState(() => selected = section),
                  ),
                ),
            ],
          ),
        ),
        if (featured.isNotEmpty) ...[
          heading(context, 'Destacados'),
          for (final article in featured) NewsArticleCard(article),
        ],
        if (regular.isNotEmpty) ...[
          heading(
            context,
            selected == NewsSection.forYou ? 'Noticias' : selected.label,
          ),
          for (final article in regular) NewsArticleCard(article),
        ],
        if (selected == NewsSection.transfers ||
            selected == NewsSection.forYou) ...[
          if (transfers.isNotEmpty) _Transfers(transfers),
        ],
        if (regular.isEmpty &&
            featured.isEmpty &&
            (selected != NewsSection.transfers &&
                    selected != NewsSection.forYou ||
                transfers.isEmpty))
          EmptyState(
            emptyTitle,
            emptyDescription,
            icon: Icons.article_outlined,
          ),
      ],
    );
  }
}

class _Transfers extends StatefulWidget {
  const _Transfers(this.transfers);

  final List<Map<String, dynamic>> transfers;

  @override
  State<_Transfers> createState() => _TransfersState();
}

class _TransfersState extends State<_Transfers> {
  bool all = false;

  @override
  Widget build(BuildContext context) {
    final shown = all
        ? widget.transfers
        : widget.transfers.take(NewsScreen.transfersPreview).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        heading(context, 'Transferencias'),
        for (final transfer in shown) TransferEventCard(transfer),
        if (!all && widget.transfers.length > shown.length)
          TextButton(
            onPressed: () => setState(() => all = true),
            child: const Text('Ver más'),
          ),
      ],
    );
  }
}

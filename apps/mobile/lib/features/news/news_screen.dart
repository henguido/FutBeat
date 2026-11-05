import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/models.dart';
import '../../core/news_links.dart';
import '../../core/providers.dart';
import '../../shared/widgets.dart';

enum NewsSection { forYou, latest, teams, players, competitions, transfers }

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
    if (title.isEmpty ||
        source.isEmpty ||
        safeNewsUri(article['url']) == null ||
        DateTime.tryParse(article['publishedAt']?.toString() ?? '') == null) {
      return false;
    }
    if (term.isNotEmpty &&
        ![title, source, article['description']].whereType<Object>().any(
          (value) => value.toString().toLowerCase().contains(term),
        )) {
      return false;
    }
    if (section == NewsSection.transfers) {
      return article['category'] == 'TRANSFER';
    }
    final kind = switch (section) {
      NewsSection.teams => 'team',
      NewsSection.players => 'player',
      NewsSection.competitions => 'competition',
      _ => null,
    };
    if (kind == null) return true;
    final subjects = article['subjects'];
    return subjects is List &&
        subjects.whereType<Map>().any((subject) {
          final id = subject['id']?.toString();
          return subject['type'] == kind &&
              id != null &&
              follows.contains('$kind:$id');
        });
  }).toList();
  if (section == NewsSection.latest) {
    shown.sort(
      (a, b) =>
          DateTime.parse(b['publishedAt'].toString())
              .compareTo(DateTime.parse(a['publishedAt'].toString())),
    );
  }
  return shown;
}

void showNewsDetails(BuildContext context, Json article) {
  final uri = safeNewsUri(article['url']);
  if (uri == null) return;
  final title = article['title']?.toString().trim() ?? '';
  final source = article['sourceName']?.toString().trim() ?? '';
  final published = DateTime.tryParse(article['publishedAt']?.toString() ?? '');
  final names = (article['associatedEntities'] as List? ?? const [])
      .whereType<String>()
      .where((name) => name.trim().isNotEmpty)
      .toList();
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(sheetContext).textTheme.titleLarge),
            const SizedBox(height: 12),
            Text(
              [
                source,
                if (published != null)
                  '${published.toLocal().day}/${published.toLocal().month}/${published.toLocal().year}',
              ].where((part) => part.isNotEmpty).join(' · '),
            ),
            if (names.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(names.join(' · ')),
            ],
            const SizedBox(height: 16),
            const Text('Lee el contenido completo en la fuente original.'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () async {
                var opened = false;
                try {
                  opened = await launchUrl(
                    uri,
                    mode: LaunchMode.externalApplication,
                  );
                } catch (_) {
                  /* Browser unavailable. */
                }
                if (!opened && sheetContext.mounted) {
                  ScaffoldMessenger.of(sheetContext).showSnackBar(
                    const SnackBar(
                      content: Text('No se pudo abrir el artículo'),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.open_in_new),
              label: const Text('Leer noticia original'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Stored articles and verified roster changes. No synthetic content.
class NewsScreen extends ConsumerStatefulWidget {
  const NewsScreen({super.key});

  static const transfersPreview = 10;

  @override
  ConsumerState<NewsScreen> createState() => _NewsScreenState();
}

class _NewsScreenState extends ConsumerState<NewsScreen> {
  Snapshot? _lastFeed;
  Timer? _rightsExpiry;
  NewsSection _section = NewsSection.forYou;
  String _query = '';

  void _scrubProtected(Snapshot? snapshot) {
    if (snapshot == null) return;
    for (final article in snapshot.news) {
      final imageUrl = Uri.tryParse(article['imageUrl']?.toString() ?? '');
      if (imageUrl?.scheme == 'https' && imageUrl?.host.isNotEmpty == true) {
        NetworkImage(imageUrl.toString()).evict();
      }
      article.remove('description');
      article.remove('imageUrl');
      article.remove('_rightsExpiresAt');
    }
  }

  void _scheduleExpiry(Snapshot? snapshot) {
    _rightsExpiry?.cancel();
    if (snapshot == null) return;
    final expiries =
        snapshot.news
            .map(
              (article) => DateTime.tryParse(
                article['_rightsExpiresAt']?.toString() ?? '',
              ),
            )
            .whereType<DateTime>()
            .toList()
          ..sort();
    if (expiries.isEmpty) return;
    final remaining = expiries.first.difference(DateTime.now());
    _rightsExpiry = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      if (!mounted || !identical(_lastFeed, snapshot)) return;
      _scrubProtected(snapshot);
      setState(() {});
    });
  }

  @override
  void dispose() {
    _rightsExpiry?.cancel();
    _scrubProtected(_lastFeed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(newsFeedProvider);
    final follows = ref.exists(followsProvider)
        ? (ref.watch(followsProvider).asData?.value ?? <String>{})
        : <String>{};
    // Riverpod may keep AsyncData while refreshing. Hide old protected text.
    final data = feed.isLoading || feed.hasError ? null : feed.asData?.value;
    if (!identical(data, _lastFeed)) {
      _scrubProtected(_lastFeed);
      _lastFeed = data;
      _scheduleExpiry(data);
    }
    Future<void> refresh() async {
      _rightsExpiry?.cancel();
      _scrubProtected(_lastFeed);
      _lastFeed = null;
      ref.invalidate(newsFeedProvider);
      await ref.read(newsFeedProvider.future);
    }

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
            'Cuando haya novedades verificadas aparecerán aquí.',
            icon: Icons.article_outlined,
          ),
        if (data.news.isNotEmpty) ...[
          TextField(
            decoration: const InputDecoration(
              labelText: 'Buscar entre las noticias cargadas',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            children: [
              for (final section in NewsSection.values)
                ChoiceChip(
                  label: Text(switch (section) {
                    NewsSection.forYou => 'Para ti',
                    NewsSection.latest => 'Últimas',
                    NewsSection.teams => 'Equipos seguidos',
                    NewsSection.players => 'Jugadores seguidos',
                    NewsSection.competitions => 'Competiciones',
                    NewsSection.transfers => 'Fichajes',
                  }),
                  selected: section == _section,
                  onSelected: (_) => setState(() => _section = section),
                ),
            ],
          ),
          if (newsForSection(
            data.news,
            _section,
            follows: follows,
            query: _query,
          ).isEmpty)
            const EmptyState(
              'Sin resultados',
              'Prueba con otro filtro o búsqueda.',
              icon: Icons.search_off,
            )
          else
            for (final article in newsForSection(
              data.news,
              _section,
              follows: follows,
              query: _query,
            ))
              NewsArticleCard(
                article,
                onOpenDetails: () => showNewsDetails(context, article),
              ),
        ],
        if (data.transfers.isNotEmpty) _Transfers(data.transfers),
      ],
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Noticias')),
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

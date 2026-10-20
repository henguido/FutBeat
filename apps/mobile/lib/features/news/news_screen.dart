import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../shared/widgets.dart';

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
          heading(context, 'Noticias'),
          for (final article in data.news) NewsArticleCard(article),
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

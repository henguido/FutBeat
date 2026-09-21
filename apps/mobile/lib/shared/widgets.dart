import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models.dart';
import '../core/providers.dart';
import '../core/theme.dart';

class EntityAvatar extends StatelessWidget {
  const EntityAvatar(this.entity, {super.key, this.size = 42});
  final Entity entity;
  final double size;
  @override
  Widget build(BuildContext context) {
    final hex = entity.json['color'] as String?;
    final color = hex == null
        ? lime
        : Color(int.parse(hex.replaceFirst('#', 'FF'), radix: 16));
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: .15),
        borderRadius: BorderRadius.circular(size / 3),
        border: Border.all(color: color.withValues(alpha: .6)),
      ),
      child: Text(
        entity.initials,
        style: TextStyle(
          fontSize: size / 3.3,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
    return Semantics(
      label: entity.name,
      image: true,
      child: entity.imageUrl == null
          ? fallback
          : Image.network(
              entity.imageUrl!,
              width: size,
              height: size,
              fit: BoxFit.contain,
              errorBuilder: (_, error, stack) => fallback,
            ),
    );
  }
}

class FollowButton extends ConsumerStatefulWidget {
  const FollowButton(this.type, this.id, {super.key});
  final String type, id;
  @override
  ConsumerState<FollowButton> createState() => _FollowButtonState();
}

class _FollowButtonState extends ConsumerState<FollowButton> {
  bool busy = false;
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(followsProvider);
    final followed =
        state.asData?.value.contains('${widget.type}:${widget.id}') ?? false;
    return IconButton(
      tooltip: state.hasError
          ? 'Reintentar seguimiento'
          : followed
          ? 'Dejar de seguir'
          : 'Seguir',
      icon: Icon(
        followed ? Icons.star_rounded : Icons.star_border_rounded,
        color: followed ? lime : muted,
      ),
      onPressed: busy || state.isLoading
          ? null
          : () async {
              setState(() => busy = true);
              try {
                if (state.hasError) {
                  ref.invalidate(followsProvider);
                } else {
                  await ref
                      .read(databaseProvider)
                      .toggle(widget.type, widget.id);
                }
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('No se pudo guardar. Intenta de nuevo.'),
                    ),
                  );
                }
              } finally {
                if (mounted) setState(() => busy = false);
              }
            },
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState(
    this.title,
    this.message, {
    super.key,
    this.icon = Icons.sports_soccer,
  });
  final String title, message;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
    child: Column(
      children: [
        Icon(icon, size: 40, color: lime),
        const SizedBox(height: 16),
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        if (message.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: muted, height: 1.5),
          ),
        ],
      ],
    ),
  );
}

class DataView extends ConsumerWidget {
  const DataView({super.key, required this.builder});
  final Widget Function(Snapshot) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(effectiveSnapshotProvider)
      .when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, stack) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const EmptyState(
                'No pudimos cargar los datos',
                'Revisa tu conexión e intenta nuevamente.',
                icon: Icons.cloud_off,
              ),
              FilledButton(
                onPressed: () async {
                  ref.invalidate(snapshotProvider);
                  try {
                    await ref.read(snapshotProvider.future);
                  } catch (_) {
                    // Keep the recoverable error state visible.
                  }
                },
                child: const Text('Reintentar'),
              ),
            ],
          ),
        ),
        data: (data) => Column(
          children: [
            if (!data.demo && data.stale)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                color: lime.withValues(alpha: .08),
                child: const Text(
                  'Los datos pueden estar desactualizados. Desliza para actualizar.',
                  style: TextStyle(color: lime, fontSize: 12),
                ),
              ),
            Expanded(child: builder(data)),
          ],
        ),
      );
}

class CalendarDataView extends ConsumerWidget {
  const CalendarDataView({
    super.key,
    required this.date,
    required this.builder,
  });

  final DateTime date;
  final Widget Function(Snapshot) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(effectiveCalendarSnapshotProvider(date))
      .when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, stack) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const EmptyState(
                'No pudimos cargar esta fecha',
                'Revisa tu conexión e intenta nuevamente.',
                icon: Icons.cloud_off,
              ),
              FilledButton(
                onPressed: () async {
                  ref.invalidate(calendarSnapshotProvider(date));
                  try {
                    await ref.read(calendarSnapshotProvider(date).future);
                  } catch (_) {
                    // Keep the recoverable error state visible.
                  }
                },
                child: const Text('Reintentar'),
              ),
            ],
          ),
        ),
        data: (data) => Column(
          children: [
            if (!data.demo && data.stale)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                color: lime.withValues(alpha: .08),
                child: const Text(
                  'Los datos pueden estar desactualizados. Desliza para actualizar.',
                  style: TextStyle(color: lime, fontSize: 12),
                ),
              ),
            Expanded(child: builder(data)),
          ],
        ),
      );
}

class DemoNotice extends StatelessWidget {
  const DemoNotice({super.key});
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 20),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: BoxDecoration(
      color: lime.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(10),
    ),
    child: const Row(
      children: [
        Icon(Icons.science_outlined, size: 16, color: lime),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            'Modo demo · resultados ficticios',
            style: TextStyle(color: lime, fontSize: 12),
          ),
        ),
      ],
    ),
  );
}

String playerPositionLabel(String value) {
  return switch (value.trim().toLowerCase()) {
    'goalkeepers' || 'goalkeeper' => 'Portero',
    'defenders' || 'defender' => 'Defensa',
    'midfielders' || 'midfielder' => 'Mediocampista',
    'forwards' || 'forward' => 'Delantero',
    _ => value.trim(),
  };
}

class PlayerProfileFacts extends StatelessWidget {
  const PlayerProfileFacts(this.player, {super.key});

  final Entity player;

  @override
  Widget build(BuildContext context) {
    final position = playerPositionLabel(
      player.json['position']?.toString() ?? '',
    );
    final number = player.json['shirtNumber'];
    final age = player.json['age'];
    final matches = player.json['matchesPlayed'];
    final goals = player.json['goals'];
    final assists = player.json['assists'];
    final rating = player.json['rating'];
    final injured = player.json['injured'] == true;
    final birthdate = player.json['dateOfBirth']?.toString() ?? '';

    final chips = <String>[
      if (position.isNotEmpty) position,
      if (number is int) 'Dorsal #$number',
      if (age is int) '$age años',
      if (matches is int) '$matches PJ',
      if (goals is int) '$goals goles',
      if (assists is int) '$assists asist.',
      if (rating is num) 'Rating ${rating.toStringAsFixed(1)}',
      if (injured) 'Lesionado',
    ];

    if (chips.isEmpty && birthdate.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      children: [
        if (chips.isNotEmpty)
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final value in chips)
                Chip(label: Text(value), visualDensity: VisualDensity.compact),
            ],
          ),
        if (birthdate.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Nacimiento: $birthdate',
            style: const TextStyle(color: muted, fontSize: 12),
          ),
        ],
      ],
    );
  }
}

class EntityTile extends StatelessWidget {
  const EntityTile(this.entity, this.type, {super.key});
  final Entity entity;
  final String type;

  String get _subtitle {
    if (type != 'player') return entity.country;

    final parts = <String>[];
    final number = entity.json['shirtNumber'];
    final position = playerPositionLabel(
      entity.json['position']?.toString() ?? '',
    );
    if (number is int) parts.add('#$number');
    if (position.isNotEmpty) parts.add(position);
    if (entity.country.isNotEmpty) parts.add(entity.country);
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: EntityAvatar(entity),
      title: Text(entity.name),
      subtitle: _subtitle.isEmpty
          ? null
          : Text(_subtitle, style: const TextStyle(color: muted)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push('/$type/${entity.id}'),
    ),
  );
}

String _contentDateLabel(Object? value) {
  final date = DateTime.tryParse(value?.toString() ?? '');
  if (date == null) return '';
  final local = date.toLocal();
  return '${local.day}/${local.month}/${local.year}';
}

class NewsArticleCard extends StatelessWidget {
  const NewsArticleCard(this.article, {super.key});

  final Json article;

  @override
  Widget build(BuildContext context) {
    final title = article['title']?.toString().trim() ?? '';
    final description = article['description']?.toString().trim() ?? '';
    final source = article['sourceName']?.toString().trim() ?? '';
    final url = article['url']?.toString().trim() ?? '';
    final date = _contentDateLabel(article['publishedAt']);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
            if (description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                description,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: muted),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    [
                      if (source.isNotEmpty) source,
                      if (date.isNotEmpty) date,
                    ].join(' · '),
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                ),
                if (url.startsWith('https://'))
                  TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: url));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Enlace de la noticia copiado'),
                        ),
                      );
                    },
                    icon: const Icon(Icons.link, size: 17),
                    label: const Text('Copiar enlace'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class TransferEventCard extends StatelessWidget {
  const TransferEventCard(this.transfer, {super.key});

  final Json transfer;

  @override
  Widget build(BuildContext context) {
    final player = transfer['playerName']?.toString().trim() ?? 'Jugador';
    final from =
        transfer['fromTeamName']?.toString().trim() ?? 'Equipo anterior';
    final to = transfer['toTeamName']?.toString().trim() ?? 'Equipo actual';
    final source = transfer['source']?.toString().trim() ?? 'GOAL API';
    final date = _contentDateLabel(transfer['detectedAt']);

    return Card(
      child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.swap_horiz)),
        title: Text(
          player,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          '$from → $to\n'
          'Cambio detectado en plantilla'
          '${date.isEmpty ? '' : ' · $date'}'
          '${source.isEmpty ? '' : ' · $source'}',
        ),
        isThreeLine: true,
      ),
    );
  }
}

Widget heading(BuildContext context, String title) => Padding(
  padding: const EdgeInsets.only(top: 12, bottom: 14),
  child: Text(
    title,
    style: Theme.of(context).textTheme.titleMedium
        ?.copyWith(fontWeight: FontWeight.bold),
  ),
);
String localTime(BuildContext context, DateTime date) =>
    MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(date),
      alwaysUse24HourFormat: MediaQuery.of(context).alwaysUse24HourFormat,
    );

import 'package:flutter/material.dart';
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
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: muted, height: 1.5),
        ),
      ],
    ),
  );
}

class DataView extends ConsumerWidget {
  const DataView({super.key, required this.builder});
  final Widget Function(Snapshot) builder;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final realtime = ref.watch(liveRealtimeConfigProvider).isConfigured;
    return ref
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
                  onPressed: () => ref.invalidate(snapshotProvider),
                  child: const Text('Reintentar'),
                ),
              ],
            ),
          ),
          data: (data) => Column(
            children: [
              if (!data.demo && data.coverage != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                  color: lime.withValues(alpha: .08),
                  child: Text(
                    '${data.coverage!['source']} · '
                    '${data.coverage!['description'] ?? (data.coverage!['partial'] == true ? 'Cobertura parcial' : 'Cobertura disponible')} · '
                    '${realtime ? 'Directo beta' : 'Sin directo'}'
                    '${data.stale ? '\nDatos antiguos: pendientes de actualizar' : ''}',
                    style: const TextStyle(color: lime, fontSize: 12),
                  ),
                ),
              Expanded(child: builder(data)),
            ],
          ),
        );
  }
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

class EntityTile extends StatelessWidget {
  const EntityTile(this.entity, this.type, {super.key});
  final Entity entity;
  final String type;
  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: EntityAvatar(entity),
      title: Text(entity.name),
      subtitle: Text(entity.country, style: const TextStyle(color: muted)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push('/$type/${entity.id}'),
    ),
  );
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
      alwaysUse24HourFormat: true,
    );

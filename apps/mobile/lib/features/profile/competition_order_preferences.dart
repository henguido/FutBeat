import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database.dart';
import '../../core/interests.dart';
import '../../core/providers.dart';

class CompetitionOrderPanel extends ConsumerWidget {
  const CompetitionOrderPanel({super.key});

  Future<void> _save(
    WidgetRef ref, {
    String? mode,
    List<String>? pinnedIds,
  }) async {
    await ref
        .read(databaseProvider)
        .savePreference(
          // Only persist the field edited by this control. Country,
          // onboarding and other order fields may have changed since build.
          competitionOrderMode: mode,
          pinnedCompetitionIds: pinnedIds,
        );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(preferenceProvider).asData?.value;
    if (current == null) return const LinearProgressIndicator();
    final follows =
        ref.watch(followsProvider).asData?.value ?? const <String>{};
    final followedIds = follows
        .where((value) => value.startsWith('competition:'))
        .map((value) => value.substring('competition:'.length))
        .toSet();
    final keys = followedIds.map((id) => 'competition:$id').toList()..sort();
    final snapshot = keys.isEmpty
        ? null
        : ref.watch(favoritesSnapshotProvider(keys.join(','))).asData?.value;
    final orderedIds = <String>[
      ...current.pinnedCompetitionIds.where(followedIds.contains),
      ...followedIds.where((id) => !current.pinnedCompetitionIds.contains(id)),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Orden de competiciones',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: CompetitionOrderMode.automatic,
                  label: Text('Automático'),
                ),
                ButtonSegment(
                  value: CompetitionOrderMode.personalized,
                  label: Text('Personalizado'),
                ),
              ],
              selected: {current.competitionOrderMode},
              onSelectionChanged: (values) => _save(ref, mode: values.first),
            ),
            const SizedBox(height: 10),
            const Text(
              'Tus equipos y competiciones fijadas siempre aparecen arriba.',
            ),
            if (current.competitionOrderMode ==
                CompetitionOrderMode.personalized) ...[
              const SizedBox(height: 12),
              if (orderedIds.isNotEmpty) ...[
                const Divider(),
                const Text(
                  'Competiciones fijadas',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: orderedIds.length,
                  onReorderItem: (oldIndex, newIndex) {
                    final next = [...orderedIds];
                    final moved = next.removeAt(oldIndex);
                    next.insert(newIndex, moved);
                    _save(ref, pinnedIds: next);
                  },
                  itemBuilder: (context, index) {
                    final id = orderedIds[index];
                    final name = snapshot?.competition(id)?.name ?? id;
                    return ListTile(
                      key: ValueKey(id),
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.push_pin_outlined),
                      title: Text(name),
                      trailing: const Icon(Icons.drag_handle),
                    );
                  },
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

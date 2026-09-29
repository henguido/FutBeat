import 'package:flutter/material.dart';

import '../../core/profile_context.dart';
import '../../core/theme.dart';

/// Profile competition + season selector (#161): the selected context as a
/// compact bar; tapping it lists only the team's real combinations, grouped
/// by season (newest first).
class ProfileContextBar extends StatelessWidget {
  const ProfileContextBar({
    required this.options,
    required this.selected,
    required this.onSelect,
    super.key,
  });

  final List<ProfileContextOption> options;
  final ProfileContextOption selected;
  final ValueChanged<ProfileContextOption> onSelect;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
    child: Material(
      color: Colors.white.withValues(alpha: .04),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey('profile-context-selector'),
        onTap: options.length < 2 ? null : () => _open(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.emoji_events_outlined, size: 16, color: lime),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  selected.label,
                  key: const ValueKey('profile-context-label'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (options.length > 1)
                const Icon(Icons.expand_more_rounded, size: 20, color: muted),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _open(BuildContext context) async {
    final choice = await showModalBottomSheet<ProfileContextOption>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _ContextSheet(options: options, selected: selected),
    );
    if (choice != null && choice.key != selected.key) onSelect(choice);
  }
}

class _ContextSheet extends StatelessWidget {
  const _ContextSheet({required this.options, required this.selected});

  final List<ProfileContextOption> options;
  final ProfileContextOption selected;

  @override
  Widget build(BuildContext context) {
    // Server order: season newest first, seasonless last.
    final groups = <String?, List<ProfileContextOption>>{};
    for (final option in options) {
      groups.putIfAbsent(option.seasonKey, () => []).add(option);
    }
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .7,
      ),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(0, 0, 0, 16),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'Temporada',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
          ),
          for (final entry in groups.entries) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(
                entry.key == null ? 'Sin temporada' : seasonLabel(entry.key),
                style: const TextStyle(
                  color: muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            for (final option in entry.value)
              ListTile(
                key: ValueKey('profile-context-option-${option.key}'),
                dense: true,
                title: Text(option.label),
                trailing: option.key == selected.key
                    ? const Icon(Icons.check_rounded, color: lime, size: 20)
                    : null,
                onTap: () => Navigator.of(context).pop(option),
              ),
          ],
        ],
      ),
    );
  }
}

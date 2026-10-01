import 'package:flutter/widgets.dart';

import 'models.dart';

/// Session memory of verified crests / logos / photos by entity id.
///
/// Every snapshot the app reads (profile, search, favorites, calendar, ...)
/// is absorbed here, so a crest hydrated lazily while one screen is open
/// reaches every other screen showing the same identity, even ones whose own
/// (older) payload still has no media.
class EntityMediaMemory extends ChangeNotifier {
  Map<String, String> _images = const {};

  /// Immutable; replaced (never mutated) on every change.
  Map<String, String> get images => _images;

  String? imageFor(String id) => _images[id];

  void absorb(Snapshot snapshot) {
    final next = {..._images};
    for (final entity in [
      ...snapshot.teams,
      ...snapshot.competitions,
      ...snapshot.players,
    ]) {
      final image = entity.imageUrl;
      if (image != null) next[entity.id] = image;
    }
    // An alias id shows the same image as its canonical entity.
    for (final MapEntry(key: alias, value: canonical)
        in snapshot.entityRedirects.entries) {
      final image = next[canonical] ?? next[alias];
      if (image == null) continue;
      next[canonical] ??= image;
      next[alias] = next[canonical]!;
    }
    if (next.length == _images.length &&
        next.entries.every((entry) => _images[entry.key] == entry.value)) {
      return;
    }
    _images = Map.unmodifiable(next);
    notifyListeners();
  }
}

/// Makes an [EntityMediaMemory] available to [entityImageOf]. Widgets only
/// rebuild when the image of an id they asked for changes.
class EntityMediaScope extends StatefulWidget {
  const EntityMediaScope({
    required this.memory,
    required this.child,
    super.key,
  });

  final EntityMediaMemory memory;
  final Widget child;

  @override
  State<EntityMediaScope> createState() => _EntityMediaScopeState();
}

class _EntityMediaScopeState extends State<EntityMediaScope> {
  @override
  void initState() {
    super.initState();
    widget.memory.addListener(_changed);
  }

  @override
  void didUpdateWidget(EntityMediaScope old) {
    super.didUpdateWidget(old);
    if (old.memory != widget.memory) {
      old.memory.removeListener(_changed);
      widget.memory.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.memory.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) =>
      _EntityMediaModel(images: widget.memory.images, child: widget.child);
}

class _EntityMediaModel extends InheritedModel<String> {
  const _EntityMediaModel({required this.images, required super.child});

  final Map<String, String> images;

  @override
  bool updateShouldNotify(_EntityMediaModel old) =>
      !identical(old.images, images);

  @override
  bool updateShouldNotifyDependent(_EntityMediaModel old, Set<String> ids) =>
      ids.any((id) => old.images[id] != images[id]);
}

/// The one image resolver for an entity avatar (team crest, competition
/// logo): the latest verified media seen this session for that id (so one
/// identity shows one image everywhere), else the entity's own verified
/// media. Null shows initials.
String? entityImageOf(BuildContext context, Entity entity) {
  final model = InheritedModel.inheritFrom<_EntityMediaModel>(
    context,
    aspect: entity.id,
  );
  return model?.images[entity.id] ?? entity.imageUrl;
}

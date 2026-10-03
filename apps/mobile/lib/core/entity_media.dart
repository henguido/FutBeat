import 'package:flutter/widgets.dart';

import 'models.dart';
import 'player_display_identity.dart';

/// Session memory of verified crests / logos / photos by entity id.
///
/// Every snapshot the app reads (profile, search, favorites, calendar, ...)
/// is absorbed here, so a crest hydrated lazily while one screen is open
/// reaches every other screen showing the same identity, even ones whose own
/// (older) payload still has no media.
class EntityMediaMemory extends ChangeNotifier {
  Map<String, String> _images = const {};
  final Map<String, ({String country, String position})> _displayTargetGuards =
      {};

  /// Alias -> canonical ids seen in every snapshot read this session. A
  /// separate notifier: redirect changes (not image changes) notify.
  final EntityRedirectMemory redirects = EntityRedirectMemory();

  /// Immutable; replaced (never mutated) on every change.
  Map<String, String> get images => _images;

  String? imageFor(String id) => _images[id];

  @override
  void dispose() {
    redirects.dispose();
    super.dispose();
  }

  void absorb(Snapshot snapshot) {
    // Presentation adjudications can be revoked by a later contradictory
    // payload. Canonical database redirects still arrive in entityRedirects;
    // only known display aliases are invalidated.
    final rejectedDisplayAliases = {
      for (final player in snapshot.players)
        if (adjudicationForAlias(player.id) != null &&
            !snapshot.entityRedirects.containsKey(player.id))
          player.id,
    };
    for (final player in snapshot.players) {
      final decision = adjudicationForVisible(player.id);
      if (decision == null) continue;
      if (player.json['displaySourceAliasId'] == decision.aliasId) {
        // Alias-only search rows are presented with the target ID/name but
        // cannot be validated as the actual target's richer profile.
        continue;
      }
      final prior = _displayTargetGuards[decision.aliasId];
      final country = _displayGuardValue(player.json['country']);
      final position = _displayGuardValue(player.json['position']);
      if (!adjudicatedVisibleMatches(decision, player.json) ||
          (prior != null &&
              (_displayGuardConflict(prior.country, country) ||
                  _displayGuardConflict(prior.position, position)))) {
        rejectedDisplayAliases.add(decision.aliasId);
      }
    }
    redirects.absorb(
      snapshot.entityRedirects,
      invalidatedAliases: rejectedDisplayAliases,
    );
    for (final alias in rejectedDisplayAliases) {
      _displayTargetGuards.remove(alias);
    }
    for (final player in snapshot.players) {
      final decision = adjudicationForVisible(player.id);
      if (decision == null ||
          rejectedDisplayAliases.contains(decision.aliasId) ||
          redirects.resolve(decision.aliasId) != decision.visibleId) {
        continue;
      }
      _displayTargetGuards[decision.aliasId] = (
        country: _displayGuardValue(player.json['country']),
        position: _displayGuardValue(player.json['position']),
      );
    }
    final next = {..._images};
    for (final alias in rejectedDisplayAliases) {
      next.remove(alias);
    }
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
      if (rejectedDisplayAliases.contains(alias)) continue;
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

String _displayGuardValue(Object? value) =>
    value?.toString().trim().toLowerCase() ?? '';

bool _displayGuardConflict(String prior, String current) =>
    prior.isNotEmpty && current.isNotEmpty && prior != current;

/// Session memory of entity redirects (alias id -> canonical id) from every
/// snapshot read. Lets ids stored before a merge (e.g. a follow of the legacy
/// `fb_comp_cr`) resolve on read without rewriting storage. Adjudicated
/// display aliases are removable when a later response contradicts them.
class EntityRedirectMemory extends ChangeNotifier {
  Map<String, String> _redirects = const {};

  /// Immutable; replaced (never mutated) on every change.
  Map<String, String> get redirects => _redirects;

  void absorb(
    Map<String, String> redirects, {
    Set<String> invalidatedAliases = const {},
  }) {
    if (redirects.isEmpty && invalidatedAliases.isEmpty) return;
    final next = {..._redirects};
    next.addAll(redirects);
    for (final alias in invalidatedAliases) {
      next.remove(alias);
    }
    if (next.length == _redirects.length &&
        next.entries.every((entry) => _redirects[entry.key] == entry.value)) {
      return;
    }
    _redirects = Map.unmodifiable(next);
    notifyListeners();
  }

  /// Follows the redirect chain (bounded, cycle-safe) like
  /// [Snapshot.resolveEntityId].
  String resolve(String id) {
    var current = id;
    final seen = <String>{};
    for (var i = 0; i < 8 && seen.add(current); i++) {
      final next = _redirects[current];
      if (next == null || next.isEmpty || next == current) break;
      current = next;
    }
    return current;
  }

  /// `type:id` follow key with its id resolved ('match' ids never redirect).
  String resolveFollowKey(String key) {
    final separator = key.indexOf(':');
    if (separator <= 0 || separator == key.length - 1) return key;
    final type = key.substring(0, separator);
    if (type == 'match') return key;
    final id = key.substring(separator + 1);
    final resolved = resolve(id);
    return resolved == id ? key : '$type:$resolved';
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

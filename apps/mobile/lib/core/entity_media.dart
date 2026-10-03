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
  final Set<String> _authoritativePlayerAliases = {};
  // A contradiction is sticky for this session. Older cached responses must
  // never reinstate an adjudication; a fresh session can evaluate it again.
  final Set<String> _revokedDisplayAliases = {};

  /// Presentation is also blocked when an explicit server redirect has
  /// superseded a local adjudication, even if no contradiction was observed.
  Set<String> get revokedDisplayAliases => Set.unmodifiable({
    ..._revokedDisplayAliases,
    ..._authoritativePlayerAliases,
  });

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
    final blockedCountBefore = revokedDisplayAliases.length;
    final newlyAuthoritative = <String>{};
    for (final entry in snapshot.entityRedirects.entries) {
      final decision = adjudicationForAlias(entry.key);
      if (decision != null &&
          !snapshot.presentationRedirectIds.contains(entry.key)) {
        // A server-side canonical redirect to another entity supersedes the
        // local presentation decision for the rest of this session.
        _authoritativePlayerAliases.add(entry.key);
        newlyAuthoritative.add(entry.key);
        _displayTargetGuards.remove(entry.key);
      }
    }
    // Presentation adjudications can be revoked by a later contradictory
    // payload. Canonical database redirects still arrive in entityRedirects;
    // only known display aliases are invalidated.
    final rejectedDisplayAliases = <String>{};
    for (final player in snapshot.players) {
      final decision = adjudicationForAlias(player.id);
      if (decision == null ||
          _authoritativePlayerAliases.contains(player.id) ||
          snapshot.entityRedirects.containsKey(player.id)) {
        continue;
      }
      final prior = _displayTargetGuards[player.id];
      if (!adjudicatedAliasMatches(decision, player.json) ||
          (prior != null &&
              (_displayGuardConflict(
                    prior.country,
                    _displayGuardValue(player.json['country']),
                  ) ||
                  _displayGuardConflict(
                    prior.position,
                    _displayGuardValue(player.json['position']),
                  )))) {
        rejectedDisplayAliases.add(player.id);
      }
    }
    for (final player in snapshot.players) {
      final decision = adjudicationForVisible(player.id);
      if (decision == null ||
          _authoritativePlayerAliases.contains(decision.aliasId)) {
        continue;
      }
      if (player.json['displaySourceAliasId'] == decision.aliasId) {
        // Alias-only search rows are presented with the target ID/name but
        // cannot be validated as the actual target's richer profile. They
        // still must not contradict a target observed earlier this session.
        final prior = _displayTargetGuards[decision.aliasId];
        if (prior != null &&
            (_displayGuardConflict(
                  prior.country,
                  _displayGuardValue(player.json['country']),
                ) ||
                _displayGuardConflict(
                  prior.position,
                  _displayGuardValue(player.json['position']),
                ))) {
          rejectedDisplayAliases.add(decision.aliasId);
        }
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
    _revokedDisplayAliases.addAll(rejectedDisplayAliases);
    final invalidatedAliases = _revokedDisplayAliases.difference(
      _authoritativePlayerAliases,
    );
    final effectiveRedirects =
        Map<String, String>.from(snapshot.entityRedirects)..removeWhere(
          (alias, target) =>
              snapshot.presentationRedirectIds.contains(alias) &&
              (_authoritativePlayerAliases.contains(alias) ||
                  invalidatedAliases.contains(alias)) &&
              adjudicationForAlias(alias)?.visibleId == target,
        );
    redirects.absorb(
      effectiveRedirects,
      invalidatedAliases: invalidatedAliases,
    );
    for (final alias in rejectedDisplayAliases) {
      _displayTargetGuards.remove(alias);
    }
    for (final player in snapshot.players) {
      final decision = adjudicationForVisible(player.id);
      if (decision == null ||
          _authoritativePlayerAliases.contains(decision.aliasId) ||
          invalidatedAliases.contains(decision.aliasId) ||
          redirects.resolve(decision.aliasId) != decision.visibleId) {
        continue;
      }
      if (player.json['displaySourceAliasId'] == decision.aliasId &&
          _displayTargetGuards.containsKey(decision.aliasId)) {
        continue; // do not replace richer target evidence with a sparse row
      }
      final prior = _displayTargetGuards[decision.aliasId];
      final country = _displayGuardValue(player.json['country']);
      final position = _displayGuardValue(player.json['position']);
      _displayTargetGuards[decision.aliasId] = (
        country: country.isNotEmpty ? country : prior?.country ?? '',
        position: position.isNotEmpty ? position : prior?.position ?? '',
      );
    }
    final next = {..._images};
    for (final alias in {...invalidatedAliases, ...newlyAuthoritative}) {
      next.remove(alias);
    }
    final freshPlayerImages = <String>{};
    for (final entity in [
      ...snapshot.teams,
      ...snapshot.competitions,
      ...snapshot.players,
    ]) {
      final image = entity.imageUrl;
      if (image != null && !invalidatedAliases.contains(entity.id)) {
        next[entity.id] = image;
        if (snapshot.players.contains(entity)) freshPlayerImages.add(entity.id);
      }
    }
    // An alias id shows the same image as its canonical entity.
    for (final MapEntry(key: alias, value: canonical)
        in effectiveRedirects.entries) {
      if (invalidatedAliases.contains(alias)) continue;
      final image =
          next[canonical] ??
          (newlyAuthoritative.contains(alias) &&
                  !freshPlayerImages.contains(alias)
              ? null
              : next[alias]);
      if (image == null) continue;
      next[canonical] ??= image;
      next[alias] = next[canonical]!;
    }
    if (next.length == _images.length &&
        next.entries.every((entry) => _images[entry.key] == entry.value)) {
      if (blockedCountBefore != revokedDisplayAliases.length) notifyListeners();
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

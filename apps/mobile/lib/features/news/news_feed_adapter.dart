import '../../core/models.dart';

({String snippet, String image, DateTime? expiresAt}) _storyRights(
  Map<String, dynamic> story,
  DateTime now,
) {
  final raw = story['rights'];
  if (raw is! Map || raw['version'] != 1) {
    return (snippet: 'ABSENT', image: 'ABSENT', expiresAt: null);
  }
  final checked = DateTime.tryParse(raw['checkedAt']?.toString() ?? '')
      ?.toUtc();
  final expires = DateTime.tryParse(raw['expiresAt']?.toString() ?? '')
      ?.toUtc();
  if (checked == null ||
      expires == null ||
      checked.isAfter(now) ||
      !expires.isAfter(checked) ||
      expires.difference(checked) > const Duration(minutes: 1)) {
    return (snippet: 'UNVERIFIED', image: 'UNVERIFIED', expiresAt: null);
  }
  if (!expires.isAfter(now)) {
    return (snippet: 'EXPIRED', image: 'EXPIRED', expiresAt: null);
  }
  String state(Object? value) => switch (value) {
    'ALLOWED' => 'ALLOWED',
    'REVOKED' => 'REVOKED',
    _ => 'UNVERIFIED',
  };
  return (
    snippet: state(raw['snippet']),
    image: state(raw['image']),
    expiresAt: expires,
  );
}

/// Adapts the optional v2 story feed to the existing v1 Noticias snapshot.
/// No extra request, persistence or inferred metadata is introduced.
Json adaptNewsFeed(Json response, {DateTime? now}) {
  // v1 has no source-level rights attestation. Keep only link-out metadata.
  if (response['schemaVersion'] == 1) {
    return {
      ...response,
      'news': [
        for (final value in (response['news'] as List? ?? const []))
          if (value is Map)
            (Map<String, dynamic>.from(value)
              ..remove('description')
              ..remove('imageUrl')),
      ],
    };
  }
  if (response['schemaVersion'] != 2 || response['stories'] is! List) {
    throw const FormatException('Versión de noticias incompatible');
  }
  final updatedAt = DateTime.tryParse(response['updatedAt']?.toString() ?? '');
  if (updatedAt == null) {
    throw const FormatException('Fecha de noticias inválida');
  }
  final current = (now ?? DateTime.now()).toUtc();
  final seen = <String>{};
  final articles = <Json>[];
  for (final value in response['stories'] as List) {
    if (value is! Map) continue;
    final story = Map<String, dynamic>.from(value);
    final rights = _storyRights(story, current);
    final id = story['clusterId']?.toString().trim() ?? '';
    if (id.isEmpty || !seen.add(id)) continue;
    final entities = story['entities'];
    final subjects = <Json>[];
    if (entities is List) {
      for (final value in entities) {
        if (value is! Map) continue;
        final type = value['type']?.toString();
        final entityId = value['id']?.toString();
        if (const {'team', 'player', 'competition'}.contains(type) &&
            entityId != null &&
            entityId.startsWith('fb_')) {
          subjects.add({'type': type, 'id': entityId});
        }
      }
    }
    final attribution = story['attribution'];
    final provider = attribution is Map
        ? attribution['provider']?.toString().trim()
        : null;
    articles.add({
      'id': id,
      'title': story['title'],
      'url': story['url'],
      'sourceName': story['sourceName'],
      'publishedAt': story['publishedAt'],
      'snippetRights': rights.snippet,
      'imageRights': rights.image,
      if (rights.expiresAt != null &&
          (rights.snippet == 'ALLOWED' || rights.image == 'ALLOWED'))
        '_rightsExpiresAt': rights.expiresAt!.toIso8601String(),
      if (rights.snippet == 'ALLOWED' && story['snippet'] is String)
        'description': story['snippet'],
      if (rights.image == 'ALLOWED' && story['imageUrl'] is String)
        'imageUrl': story['imageUrl'],
      if (provider != null && provider.isNotEmpty) 'provider': provider,
      'subjects': subjects,
      'category': story['category'],
      'storyState': story['storyState'],
      if (story['transferStatus'] is String)
        'transferStatus': story['transferStatus'],
    });
  }
  return {
    'schemaVersion': 1,
    'demo': false,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'competitions': const <dynamic>[],
    'teams': const <dynamic>[],
    'players': const <dynamic>[],
    'matches': const <dynamic>[],
    'standings': const <dynamic>[],
    'news': articles,
    'transfers': const <dynamic>[],
  };
}

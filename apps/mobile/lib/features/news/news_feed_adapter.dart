import '../../core/models.dart';

/// Adapts the optional v2 story feed to the existing v1 Noticias snapshot.
/// No extra request, persistence or inferred metadata is introduced.
Json adaptNewsFeed(Json response) {
  if (response['schemaVersion'] == 1) return response;
  if (response['schemaVersion'] != 2 || response['stories'] is! List) {
    throw const FormatException('Versión de noticias incompatible');
  }
  final updatedAt = DateTime.tryParse(response['updatedAt']?.toString() ?? '');
  if (updatedAt == null) {
    throw const FormatException('Fecha de noticias inválida');
  }
  final seen = <String>{};
  final articles = <Json>[];
  for (final value in response['stories'] as List) {
    if (value is! Map) continue;
    final story = Map<String, dynamic>.from(value);
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
      if (story['snippet'] is String) 'description': story['snippet'],
      if (story['imageUrl'] is String) 'imageUrl': story['imageUrl'],
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

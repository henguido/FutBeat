/// Only public HTTPS article/image URLs can leave the app. The server is the
/// authority for content rights; this guard prevents unsafe URL schemes and
/// local targets from becoming navigation actions.
Uri? safeNewsUri(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  if (text.isEmpty || text.contains(RegExp(r'[\s\\]'))) return null;
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.scheme != 'https' ||
      !uri.hasAuthority ||
      uri.userInfo.isNotEmpty ||
      uri.host.isEmpty ||
      !uri.host.contains('.') ||
      uri.host.endsWith('.local') ||
      uri.host.endsWith('.localhost') ||
      uri.host == 'localhost' ||
      uri.host.contains(':') ||
      RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(uri.host)) {
    return null;
  }
  return uri;
}

/// Defense for cards reached outside the link-only feed adapter (profiles).
/// Missing, ambiguous or expired server authorization never permits media.
bool newsMediaAuthorized(Object? rights, {DateTime? now}) {
  if (rights is! Map ||
      rights['status'] != 'ALLOWED' ||
      rights['verified'] != true) {
    return false;
  }
  final expiry = rights['expiresAt'];
  if (expiry is! String ||
      !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$').hasMatch(expiry)) {
    return false;
  }
  final parsed = DateTime.tryParse(expiry);
  // DateTime.parse normalizes impossible dates; require a canonical roundtrip.
  if (parsed == null ||
      parsed.toIso8601String() != expiry.replaceFirst('Z', '.000Z')) {
    return false;
  }
  return parsed.isAfter((now ?? DateTime.now()).toUtc());
}

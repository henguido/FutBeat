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

// Only these exact switch arms in the dedicated media validator are exempt.
// Any other use of these hosts (including a URL or a changed validator)
// still reaches the original provider scan.
export function stripStaticMediaHostCases(path, source) {
  if (path.href !== new URL('../../../apps/mobile/lib/core/sports_image_cache.dart', import.meta.url).href) return source;
  return source.split('\n').map((line) => {
    const exact = line.trim();
    return exact === "'media.api-sports.io' => _apiSportsMedia.hasMatch(uri.path)," ||
      exact === "'r2.thesportsdb.com' => _sportsDbMedia.hasMatch(uri.path),"
      ? '' : line;
  }).join('\n');
}

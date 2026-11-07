import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'qa_development.dart';

typedef SportsImageFetch = Future<Uint8List> Function(Uri uri);

/// Private, bounded cache for verified sports entity media. A file belongs to
/// both a canonical ID and its exact HTTPS URL; changing either cannot show a
/// previous person's image. Callers must stop supplying URLs when rights or
/// verification are revoked.
class SportsImageDiskCache {
  SportsImageDiskCache({
    required this.directory,
    SportsImageFetch? fetch,
    DateTime Function()? clock,
    this.onError,
    this.ttl = const Duration(days: 7),
    this.maxBytes = 32 * 1024 * 1024,
    this.maxEntries = 400,
    this.maxImageBytes = 2 * 1024 * 1024,
    Duration downloadTimeout = const Duration(seconds: 15),
  }) : fetch = fetch ?? ((uri) => _fetchImage(uri, downloadTimeout)),
       clock = clock ?? DateTime.now {
    // Tests may shorten the owned HTTP deadline; callers cannot expand it.
    if (downloadTimeout <= Duration.zero ||
        downloadTimeout > const Duration(seconds: 15)) {
      throw ArgumentError.value(downloadTimeout, 'downloadTimeout');
    }
  }

  final Directory directory;
  final SportsImageFetch fetch;
  final DateTime Function() clock;
  final void Function(Object error)? onError;
  final Duration ttl;
  final int maxBytes;
  final int maxEntries;
  final int maxImageBytes;
  final Map<String, Future<File?>> _inFlight = {};
  final Map<String, ({DateTime modified, int size})> _validatedFiles = {};
  int _validationCount = 0;

  @visibleForTesting
  int get validationCount => _validationCount;
  @visibleForTesting
  int get validatedEntryCount => _validatedFiles.length;
  Future<void>? _eviction;
  bool _evictionRequested = false;

  static final Future<SportsImageDiskCache> shared = () async {
    final root = await getApplicationCacheDirectory();
    final cache = SportsImageDiskCache(
      directory: Directory(
        '${root.path}${Platform.pathSeparator}sports-media-v1',
      ),
    );
    await cache.removeAbandonedPartials();
    return cache;
  }();

  static Uri? validUri(String? value) {
    final uri = Uri.tryParse(value?.trim() ?? '');
    return uri != null &&
            uri.scheme == 'https' &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty
        ? uri
        : null;
  }

  /// Static media paths observed in verified entity records. Provider API
  /// routes, credentials and arbitrary redirects never enter this channel.
  static final _goalMedia = RegExp(
    r'^/badges/(?:(?:players|teams|tournaments|logo_leagues)/)?[A-Za-z0-9_-][A-Za-z0-9_.-]*\.(png|jpg|jpeg|webp)$',
  );
  static final _apiSportsMedia = RegExp(
    r'^/football/(teams|leagues)/[0-9]+\.png$',
  );
  static final _sportsDbMedia = RegExp(
    r'^/images/media/(team|league)/badge/[A-Za-z0-9_-]+\.(png|jpg|jpeg|webp)$',
  );

  static bool allowedRemoteUri(Uri uri) {
    if (uri.scheme != 'https' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return false;
    }
    return switch (uri.host) {
      'media.goal-api.com' => _goalMedia.hasMatch(uri.path),
      'media.api-sports.io' => _apiSportsMedia.hasMatch(uri.path),
      'r2.thesportsdb.com' => _sportsDbMedia.hasMatch(uri.path),
      _ => false,
    };
  }

  Future<File?> resolve({required String canonicalId, required String? url}) {
    final uri = validUri(url);
    if (!canonicalId.startsWith('fb_') || uri == null) {
      return Future.value(null);
    }
    final key = sha256.convert('$canonicalId\u0000$uri'.codeUnits).toString();
    return _inFlight.putIfAbsent(key, () async {
      try {
        return await _resolve(key, uri);
      } finally {
        _inFlight.remove(key);
      }
    });
  }

  Future<File?> _resolve(String key, Uri uri) async {
    try {
      await directory.create(recursive: true);
      final file = File('${directory.path}${Platform.pathSeparator}$key.img');
      // A peer may replace a corrupt file while its decoder is pending.
      // Retry one changed disk version, never delete or memoize a stale one.
      for (var read = 0; read < 2 && await file.exists(); read++) {
        final stat = await file.stat();
        var valid = false;
        if (stat.size > 0 &&
            stat.size <= maxImageBytes &&
            clock().difference(stat.modified) < ttl) {
          final signature = (modified: stat.modified, size: stat.size);
          valid =
              _validatedFiles[file.path] == signature ||
              await _validImage(await file.readAsBytes());
        }
        if (!_sameFileVersion(stat, await file.stat())) {
          _validatedFiles.remove(file.path);
          if (read == 0) continue;
          return null;
        }
        if (valid) {
          _rememberValidation(file.path, (
            modified: stat.modified,
            size: stat.size,
          ));
          return file;
        }
        _validatedFiles.remove(file.path);
        await file.delete();
        break;
      }
      _validatedFiles.remove(file.path);
      final bytes = await fetch(uri);
      if (bytes.isEmpty ||
          bytes.length > maxImageBytes ||
          !await _validImage(bytes)) {
        return null;
      }
      final temporary = File(
        '${file.path}.${clock().microsecondsSinceEpoch}.part',
      );
      try {
        await temporary.writeAsBytes(bytes, flush: true);
        await temporary.rename(file.path);
        final stat = await file.stat();
        _rememberValidation(file.path, (
          modified: stat.modified,
          size: stat.size,
        ));
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
      await evict();
      return await file.exists() ? file : null;
    } catch (error) {
      // The image remains optional: failed downloads and unavailable storage
      // show the caller's placeholder without breaking Match Center.
      onError?.call(error);
      return null;
    }
  }

  bool _sameFileVersion(FileStat expected, FileStat current) =>
      expected.type == current.type &&
      expected.modified == current.modified &&
      expected.size == current.size;

  void _rememberValidation(
    String path,
    ({DateTime modified, int size}) signature,
  ) {
    _validatedFiles.remove(path);
    _validatedFiles[path] = signature;
    final limit = maxEntries > 0 ? maxEntries : 0;
    while (_validatedFiles.length > limit) {
      _validatedFiles.remove(_validatedFiles.keys.first);
    }
  }

  Future<bool> _validImage(Uint8List bytes) async {
    _validationCount++;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      // Entity photos and crests do not need unbounded source dimensions.
      if (descriptor.width <= 0 ||
          descriptor.height <= 0 ||
          descriptor.width > 8192 ||
          descriptor.height > 8192 ||
          descriptor.width * descriptor.height > 16 * 1024 * 1024) {
        return false;
      }
      codec = await descriptor.instantiateCodec(
        targetWidth: 1,
        targetHeight: 1,
      );
      image = (await codec.getNextFrame()).image;
      return true;
    } catch (error) {
      onError?.call(error);
      return false;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  Future<void> evict() {
    _evictionRequested = true;
    final active = _eviction;
    if (active != null) return active;
    // A lineup can finish many downloads together. Share their traversal
    // instead of queuing a full directory scan for every single image.
    final run = Future<void>.microtask(() async {
      try {
        do {
          _evictionRequested = false;
          await _evict();
          // A download may have written after the scan began. Run again
          // before completing any waiter, so byte/entry limits still hold.
        } while (_evictionRequested);
      } finally {
        _eviction = null;
      }
    });
    _eviction = run;
    return run;
  }

  Future<void> _evict() async {
    if (!await directory.exists()) {
      _validatedFiles.clear();
      return;
    }
    final files = <({File file, FileStat stat})>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.img')) {
        // A partial file can belong to another active download.
        continue;
      }
      FileStat stat;
      try {
        stat = await entity.stat();
      } on FileSystemException {
        // A peer may have replaced a file while this scan was in progress.
        continue;
      }
      if (clock().difference(stat.modified) >= ttl ||
          stat.size > maxImageBytes) {
        _validatedFiles.remove(entity.path);
        if (_sameFileVersion(stat, await entity.stat())) await entity.delete();
      } else {
        files.add((file: entity, stat: stat));
      }
    }
    files.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
    var bytes = files.fold<int>(0, (sum, item) => sum + item.stat.size);
    while (files.length > maxEntries || bytes > maxBytes) {
      final oldest = files.removeAt(0);
      bytes -= oldest.stat.size;
      _validatedFiles.remove(oldest.file.path);
      if (_sameFileVersion(oldest.stat, await oldest.file.stat())) {
        await oldest.file.delete();
      }
    }
    final retainedPaths = files.map((entry) => entry.file.path).toSet();
    _validatedFiles.removeWhere((path, _) => !retainedPaths.contains(path));
  }

  Future<void> removeAbandonedPartials() async {
    if (!await directory.exists()) return;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.part')) continue;
      try {
        if (clock().difference((await entity.stat()).modified) >
            const Duration(hours: 1)) {
          await entity.delete();
        }
      } on FileSystemException {
        // Another process may have completed or removed the partial file.
      }
    }
  }

  static Future<Uint8List> _fetchImage(Uri uri, Duration deadline) async {
    if (!allowedRemoteUri(uri)) {
      throw const HttpException('Image origin is not permitted');
    }
    final client =
        (passivePreview ? createPassivePreviewHttpClient() : HttpClient())
          ..connectionTimeout = const Duration(seconds: 5);
    Future<Uint8List> download() async {
      var target = uri;
      for (var redirect = 0; redirect <= 3; redirect++) {
        final request = await client.getUrl(target);
        request.followRedirects = false;
        final response = await request.close().timeout(
          const Duration(seconds: 8),
        );
        if (response.isRedirect && redirect < 3) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          final next = location == null
              ? null
              : validUri(target.resolve(location).toString());
          // Discarded bodies may never finish (or be unbounded). Cancel
          // the subscription rather than draining provider bytes we cannot use.
          await response.listen(null).cancel();
          if (next == null || !allowedRemoteUri(next)) {
            throw const HttpException('Unsafe image redirect');
          }
          target = next;
          continue;
        }
        if (response.statusCode != HttpStatus.ok ||
            response.headers.contentType?.primaryType != 'image' ||
            response.contentLength > 2 * 1024 * 1024) {
          // Discarded bodies may never finish (or be unbounded). Cancel
          // the subscription rather than draining provider bytes we cannot use.
          await response.listen(null).cancel();
          throw const HttpException('Image response rejected');
        }
        final builder = BytesBuilder(copy: false);
        await for (final chunk in response.timeout(
          const Duration(seconds: 8),
        )) {
          builder.add(chunk);
          if (builder.length > 2 * 1024 * 1024) {
            throw const HttpException('Image too large');
          }
        }
        return builder.takeBytes();
      }
      throw const HttpException('Too many image redirects');
    }

    try {
      // An idle timeout alone lets a slow-drip body (or redirects) keep the
      // canonical in-flight slot forever. Bound the complete HTTP operation.
      return await download().timeout(deadline);
    } finally {
      client.close(force: true);
    }
  }
}

/// Displays a cached image only for the currently supplied canonical ID and
/// verified URL. No URL means no disk read, including after media revocation.
class SportsImage extends StatefulWidget {
  const SportsImage({
    required this.canonicalId,
    required this.url,
    required this.fallback,
    required this.width,
    required this.height,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.cacheWidth,
    this.cache,
    super.key,
  });

  final String canonicalId;
  final String? url;
  final Widget fallback;
  final double width;
  final double height;
  final BoxFit fit;
  final Alignment alignment;
  final int? cacheWidth;
  final SportsImageDiskCache? cache;

  @override
  State<SportsImage> createState() => _SportsImageState();
}

class _SportsImageState extends State<SportsImage> {
  late Future<File?> _image;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(SportsImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.canonicalId != widget.canonicalId ||
        oldWidget.url != widget.url ||
        oldWidget.cache != widget.cache) {
      _load();
    }
  }

  void _load() {
    _image = () async {
      if (!widget.canonicalId.startsWith('fb_') ||
          SportsImageDiskCache.validUri(widget.url) == null) {
        return null;
      }
      final cache = widget.cache ?? await SportsImageDiskCache.shared;
      return cache.resolve(canonicalId: widget.canonicalId, url: widget.url);
    }();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.canonicalId.startsWith('fb_') ||
        SportsImageDiskCache.validUri(widget.url) == null) {
      return widget.fallback;
    }
    return FutureBuilder<File?>(
      key: ValueKey('${widget.canonicalId}\u0000${widget.url}'),
      future: _image,
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (file == null) return widget.fallback;
        return Image.file(
          file,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          alignment: widget.alignment,
          cacheWidth: widget.cacheWidth,
          errorBuilder: (_, _, _) => widget.fallback,
        );
      },
    );
  }
}

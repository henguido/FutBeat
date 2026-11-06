/// Opt-in, in-memory counters for a supervised QA session.
/// No URLs, query values, identifiers, response bodies or credentials are kept.
class QaDiagnostics {
  QaDiagnostics({this.onRecord});

  /// Receives only fixed endpoint names and aggregate measurements.
  final void Function(
    String endpoint,
    String event,
    int? milliseconds,
    int? bytes,
  )?
  onRecord;
  final Map<String, int> _counts = {};
  final Map<String, int> _milliseconds = {};
  final Map<String, int> _bytes = {};

  void record(String endpoint, String event, {Duration? elapsed, int? bytes}) {
    // Only fixed API route names are accepted; never record query parameters.
    if (!RegExp(r'^/[a-z0-9/-]+$').hasMatch(endpoint)) return;
    final key = '$endpoint:$event';
    _counts.update(key, (value) => value + 1, ifAbsent: () => 1);
    if (elapsed != null) {
      _milliseconds.update(
        key,
        (value) => value + elapsed.inMilliseconds,
        ifAbsent: () => elapsed.inMilliseconds,
      );
    }
    if (bytes != null) {
      _bytes.update(key, (value) => value + bytes, ifAbsent: () => bytes);
    }
    onRecord?.call(endpoint, event, elapsed?.inMilliseconds, bytes);
  }

  Map<String, Object> snapshot() => {
    'counts': Map<String, int>.unmodifiable(_counts),
    'totalMilliseconds': Map<String, int>.unmodifiable(_milliseconds),
    // Content-Length is optional and may differ from actual socket bytes.
    'reportedContentLengthBytes': Map<String, int>.unmodifiable(_bytes),
  };
}

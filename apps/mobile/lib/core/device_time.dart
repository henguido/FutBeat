import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _deviceChannel = MethodChannel('futbeat/device');
String? _initialZone;

/// Native Android supplies the IANA identifier. Desktop test processes may
/// configure their system zone through TZ; no country-to-zone mapping exists.
String systemCalendarTimeZone() =>
    _initialZone ??
    (Platform.isAndroid
        ? ''
        : Platform.environment['TZ'] ?? DateTime.now().timeZoneName);

/// Android's configured zone, never inferred from country, SIM, IP or GPS.
Future<String?> readDeviceTimeZone() async {
  if (!Platform.isAndroid) {
    return systemCalendarTimeZone();
  }
  return _deviceChannel
      .invokeMethod<String>('timeZone')
      .timeout(const Duration(seconds: 2));
}

Future<void> initializeDeviceTime() async {
  try {
    _initialZone = await readDeviceTimeZone();
  } catch (_) {
    // The clock retries on resume. No guessed regional calendar is requested.
  }
}

DateTime deviceNow() => DateTime.now();

String deviceDayLabel(DateTime instant, {DateTime? now}) {
  final date = instant.toLocal();
  final anchor = (now ?? deviceNow()).toLocal();
  // Civil dates, rather than elapsed 24 h: DST days can have 23 or 25 h.
  final days = DateTime.utc(
    date.year,
    date.month,
    date.day,
  ).difference(DateTime.utc(anchor.year, anchor.month, anchor.day)).inDays;
  if (days == 0) return 'Hoy';
  if (days == 1) return 'Mañana';
  const weekdays = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
  const months = [
    'ene',
    'feb',
    'mar',
    'abr',
    'may',
    'jun',
    'jul',
    'ago',
    'sep',
    'oct',
    'nov',
    'dic',
  ];
  return '${weekdays[date.weekday - 1]} ${date.day} ${months[date.month - 1]}';
}

class DeviceClock extends ChangeNotifier {
  DeviceClock({
    String? zoneId,
    DateTime Function()? now,
    Future<String?> Function()? readZone,
  }) : _zoneId =
           zoneId ??
           _initialZone ??
           (Platform.isAndroid ? null : systemCalendarTimeZone()),
       _now = now ?? deviceNow,
       _readZone = readZone ?? readDeviceTimeZone {
    final local = this.now;
    _signature =
        '$_zoneId/${local.year}/${local.month}/${local.day}/${local.timeZoneOffset}';
  }

  final DateTime Function() _now;
  final Future<String?> Function() _readZone;
  String? _zoneId;
  String? _signature;
  Timer? _timer;
  bool _disposed = false;
  Future<void>? _refreshTask;
  bool _refreshAgain = false;
  bool _nativeListening = false;
  bool _started = false;
  DateTime get now => _now().toLocal();
  String get calendarZoneId => _zoneId ?? '';

  void start({bool? android}) {
    if (_started || _disposed) return;
    _started = true;
    if (android ?? Platform.isAndroid) {
      _nativeListening = true;
      _deviceChannel.setMethodCallHandler((call) async {
        if (call.method == 'clockChanged') await refresh();
      });
    }
    unawaited(refresh());
  }

  Future<void> refresh() {
    if (_disposed) return Future.value();
    final pending = _refreshTask;
    if (pending != null) {
      _refreshAgain = true;
      return pending;
    }
    late final Future<void> task;
    task = _refresh().whenComplete(() {
      if (identical(_refreshTask, task)) _refreshTask = null;
    });
    _refreshTask = task;
    return task;
  }

  Future<void> _refresh() async {
    do {
      _refreshAgain = false;
      try {
        final zone = await _readZone();
        if (_disposed) return;
        _zoneId = zone != null && zone.isNotEmpty ? zone : null;
      } catch (_) {
        // Do not acquire a calendar using a previous region after a change.
        _zoneId = null;
      }
    } while (_refreshAgain && !_disposed);
    if (_disposed) return;
    final local = now;
    final signature =
        '$_zoneId/${local.year}/${local.month}/${local.day}/${local.timeZoneOffset}';
    if (signature != _signature) {
      _signature = signature;
      notifyListeners();
    }
    if (!_started) return;
    _timer?.cancel();
    final midnight = DateTime(local.year, local.month, local.day + 1);
    final untilMidnight = midnight.difference(local);
    // Native broadcasts handle zone/time changes immediately. This bounded
    // local timer also catches midnight; it never polls a sports provider.
    final delay = untilMidnight < const Duration(minutes: 1)
        ? untilMidnight
        : const Duration(minutes: 1);
    _timer = Timer(
      delay > Duration.zero ? delay : const Duration(milliseconds: 1),
      () => unawaited(refresh()),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }

  void stop() {
    _started = false;
    _timer?.cancel();
    _timer = null;
    if (_nativeListening) _deviceChannel.setMethodCallHandler(null);
    _nativeListening = false;
  }
}

final deviceClockProvider = Provider<DeviceClock>((ref) {
  final clock = DeviceClock();
  ref.onDispose(clock.dispose);
  return clock;
});

class DeviceTimeScope extends InheritedNotifier<DeviceClock> {
  const DeviceTimeScope({
    required DeviceClock clock,
    required super.child,
    super.key,
  }) : super(notifier: clock);

  static DeviceClock? watch(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DeviceTimeScope>()?.notifier;
}

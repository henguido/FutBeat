import 'dart:async';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/theme.dart';

/// Local clock only: no HTTP. Rechecks on resume without waiting for Realtime.
class LiveFreshnessNotice extends StatefulWidget {
  const LiveFreshnessNotice(this.match, {super.key, this.now = DateTime.now});
  final FootballMatch match;
  final DateTime Function() now;
  @override
  State<LiveFreshnessNotice> createState() => _LiveFreshnessNoticeState();
}

class _LiveFreshnessNoticeState extends State<LiveFreshnessNotice>
    with WidgetsBindingObserver {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  void _start() {
    _timer?.cancel();
    if (widget.match.isLive &&
        (WidgetsBinding.instance.lifecycleState == null ||
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed)) {
      _timer = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void didUpdateWidget(covariant LiveFreshnessNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    _start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _start();
    if (state == AppLifecycleState.resumed && mounted) setState(() {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      !widget.match.liveDataStaleAt(widget.now())
      ? const SizedBox.shrink()
      : const Padding(
          key: ValueKey('live-last-known'),
          padding: EdgeInsets.symmetric(vertical: 5),
          child: Text(
            'Último marcador conocido · Sin actualización reciente',
            textAlign: TextAlign.center,
            style: TextStyle(color: muted, fontSize: 11),
          ),
        );
}

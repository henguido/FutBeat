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
      : Padding(
          key: ValueKey('live-last-known'),
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Semantics(
            label: 'LIVE sin sincronizar',
            child: const Icon(
              Icons.sync_problem_outlined,
              color: muted,
              size: 14,
            ),
          ),
        );
}

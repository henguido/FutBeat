import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// An illustrative pitch for a LIVE match. It never claims to track a ball,
/// possession, or the location of an attack.
class LiveFieldCard extends StatefulWidget {
  const LiveFieldCard({
    super.key,
    required this.homeName,
    required this.awayName,
    required this.score,
    required this.status,
    this.latestEvent,
  });

  final String homeName;
  final String awayName;
  final String score;
  final String status;
  final String? latestEvent;

  @override
  State<LiveFieldCard> createState() => _LiveFieldCardState();
}

class _LiveFieldCardState extends State<LiveFieldCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
    lowerBound: .45,
    upperBound: 1,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Card(
      key: const ValueKey('live-field-card'),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, _) => Opacity(
                    opacity: reduceMotion ? 1 : _pulse.value,
                    child: const Icon(Icons.circle, size: 9, color: lime),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    widget.status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: lime,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Vista ilustrativa',
                  style: TextStyle(color: muted, fontSize: 11),
                ),
              ],
            ),
            const SizedBox(height: 12),
            AspectRatio(
              aspectRatio: 2.15,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(child: CustomPaint(painter: _PitchPainter())),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0E1B19).withValues(alpha: .92),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      widget.score,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 9),
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.homeName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.awayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            if (widget.latestEvent != null) ...[
              const SizedBox(height: 12),
              Text(
                widget.latestEvent!,
                key: const ValueKey('live-field-latest-event'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: lime,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            const SizedBox(height: 6),
            const Text(
              'Sin seguimiento de balón ni posición de ataque.',
              style: TextStyle(color: muted, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}

class _PitchPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(12)),
      Paint()..color = const Color(0xFF123A2B),
    );
    final line = Paint()
      ..color = const Color(0xFF8AC8A0).withValues(alpha: .45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final inset = rect.deflate(12);
    canvas.drawRect(inset, line);
    canvas.drawLine(
      Offset(size.width / 2, 12),
      Offset(size.width / 2, size.height - 12),
      line,
    );
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      size.height * .17,
      line,
    );
    final boxWidth = size.width * .14;
    final boxHeight = size.height * .54;
    canvas.drawRect(
      Rect.fromLTWH(12, (size.height - boxHeight) / 2, boxWidth, boxHeight),
      line,
    );
    canvas.drawRect(
      Rect.fromLTWH(
        size.width - 12 - boxWidth,
        (size.height - boxHeight) / 2,
        boxWidth,
        boxHeight,
      ),
      line,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

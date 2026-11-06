import 'package:flutter/material.dart';

enum SkeletonLayout { list, profile, match }

/// Only for a resource with no presentation data yet. Static placeholders
/// create no ticker and respect reduced motion without perpetual animation.
class ContentSkeleton extends StatelessWidget {
  const ContentSkeleton({
    super.key,
    this.layout = SkeletonLayout.list,
    this.label = 'Cargando',
  });

  final SkeletonLayout layout;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    child: ExcludeSemantics(
      child: ListView.builder(
        key: const ValueKey('content-skeleton'),
        padding: const EdgeInsets.all(20),
        itemCount: 4,
        itemBuilder: (context, index) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: index == 0 && layout != SkeletonLayout.list
                  ? Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            const SkeletonBlock(
                              width: 64,
                              height: 64,
                              radius: 32,
                            ),
                            if (layout == SkeletonLayout.match)
                              const SkeletonBlock(
                                width: 64,
                                height: 64,
                                radius: 32,
                              ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        const FractionallySizedBox(
                          widthFactor: .65,
                          child: SkeletonBlock(height: 16),
                        ),
                      ],
                    )
                  : const Row(
                      children: [
                        SkeletonBlock(width: 40, height: 40, radius: 20),
                        SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              FractionallySizedBox(
                                widthFactor: .8,
                                child: SkeletonBlock(height: 12),
                              ),
                              SizedBox(height: 12),
                              FractionallySizedBox(
                                widthFactor: .55,
                                child: SkeletonBlock(height: 10),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    ),
  );
}

class SkeletonBlock extends StatelessWidget {
  const SkeletonBlock({
    super.key,
    this.width,
    required this.height,
    this.radius = 6,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .06),
      borderRadius: BorderRadius.circular(radius),
    ),
  );
}

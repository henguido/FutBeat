import 'package:flutter/material.dart';

import '../../core/theme.dart';

// Shared building blocks for entity profiles (team, player): collapsible
// header + pinned compact tabs, compact sections and empty states.

const profileHeaderTop = Color(0xFF1B2B31);
const profileHeaderBottom = Color(0xFF0F181C);
const profileCardBorder = Color(0xFF2B373D);

/// Compact pinned tab bar shared by profile screens.
TabBar profileTabBar(List<String> tabs) => TabBar(
  isScrollable: true,
  tabAlignment: TabAlignment.start,
  labelPadding: const EdgeInsets.symmetric(horizontal: 14),
  labelColor: Colors.white,
  unselectedLabelColor: muted,
  labelStyle: const TextStyle(
    fontFamily: 'FutBeatRoboto',
    fontSize: 14,
    fontWeight: FontWeight.w800,
  ),
  unselectedLabelStyle: const TextStyle(
    fontFamily: 'FutBeatRoboto',
    fontSize: 14,
    fontWeight: FontWeight.w600,
  ),
  indicatorSize: TabBarIndicatorSize.label,
  indicator: const UnderlineTabIndicator(
    borderSide: BorderSide(color: lime, width: 3),
    borderRadius: BorderRadius.vertical(top: Radius.circular(3)),
  ),
  dividerColor: Colors.transparent,
  tabs: [for (final tab in tabs) Tab(text: tab, height: 42)],
);

class ProfileHeaderChip extends StatelessWidget {
  const ProfileHeaderChip({
    required this.icon,
    required this.label,
    this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = onTap == null ? muted : lime;
    return Material(
      color: color.withValues(alpha: .1),
      shape: StadiumBorder(
        side: BorderSide(color: color.withValues(alpha: .35)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ProfileInfoCard extends StatelessWidget {
  const ProfileInfoCard(this.rows, {super.key});

  final List<(IconData, String, String)> rows;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Column(
        children: [
          for (final (icon, label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(icon, size: 18, color: muted),
                  const SizedBox(width: 12),
                  // Label hugs the left, value hugs the right edge; both
                  // shrink with ellipsis when they cannot fit together.
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                          flex: 2,
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: muted, fontSize: 13),
                          ),
                        ),
                        Flexible(
                          flex: 3,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 12),
                            child: Text(
                              value,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.end,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

/// Compact empty state: informative without taking the whole screen.
class InlineEmpty extends StatelessWidget {
  const InlineEmpty(this.icon, this.title, {this.detail, super.key});

  final IconData icon;
  final String title;
  final String? detail;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(vertical: 4),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .03),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: profileCardBorder),
    ),
    child: Row(
      children: [
        Icon(icon, size: 22, color: muted.withValues(alpha: .7)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              if (detail != null)
                Text(
                  detail!,
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class ProfileSectionTitle extends StatelessWidget {
  const ProfileSectionTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 14, 2, 8),
    child: Text(
      title,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
    ),
  );
}

class ProfileTabBarHeader extends SliverPersistentHeaderDelegate {
  ProfileTabBarHeader(this.tabBar);

  final TabBar tabBar;

  @override
  double get minExtent => tabBar.preferredSize.height + 1;

  @override
  double get maxExtent => tabBar.preferredSize.height + 1;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => DecoratedBox(
    decoration: const BoxDecoration(
      color: profileHeaderBottom,
      border: Border(bottom: BorderSide(color: profileCardBorder)),
    ),
    child: Align(alignment: Alignment.centerLeft, child: tabBar),
  );

  @override
  bool shouldRebuild(covariant ProfileTabBarHeader oldDelegate) =>
      oldDelegate.tabBar != tabBar;
}

class ProfileTabList extends StatelessWidget {
  const ProfileTabList(this.storageKey, this.children, {super.key});

  final String storageKey;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => CustomScrollView(
    key: PageStorageKey<String>(storageKey),
    slivers: [
      SliverOverlapInjector(
        handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
        sliver: SliverList(delegate: SliverChildListDelegate(children)),
      ),
    ],
  );
}

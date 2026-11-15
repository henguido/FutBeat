import 'package:flutter/material.dart';

import '../../core/theme.dart';

class ProfileSection extends StatelessWidget {
  const ProfileSection({
    required this.title,
    required this.children,
    super.key,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Text(
          title.toUpperCase(),
          style: const TextStyle(
            color: muted,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.4,
          ),
        ),
      ),
      Card(child: Column(children: _separated(children))),
    ],
  );

  List<Widget> _separated(List<Widget> values) => [
    for (final (index, child) in values.indexed) ...[
      if (index > 0) const Divider(height: 1),
      child,
    ],
  ];
}

class ProfileDestinationTile extends StatelessWidget {
  const ProfileDestinationTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.trailing,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => ListTile(
    minVerticalPadding: 12,
    leading: Icon(icon),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
    subtitle: subtitle == null ? null : Text(subtitle!),
    trailing: trailing ?? const Icon(Icons.chevron_right),
    onTap: onTap,
  );
}

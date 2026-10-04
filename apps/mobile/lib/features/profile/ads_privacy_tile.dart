import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ads.dart';

/// Opens Google's privacy options form (UMP). Shown only when UMP says the
/// entry point is required; the form and its wording are Google's.
class AdsPrivacyOptionsTile extends ConsumerWidget {
  const AdsPrivacyOptionsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final required =
        ref.watch(adsPrivacyOptionsRequiredProvider).value ?? false;
    if (!required) return const SizedBox.shrink();
    return ListTile(
      key: const ValueKey('ads-privacy-options'),
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.privacy_tip_outlined),
      title: const Text('Opciones de privacidad'),
      onTap: () =>
          unawaited(ref.read(adsConsentProvider.notifier).showPrivacyOptions()),
    );
  }
}

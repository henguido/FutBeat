import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/entitlements.dart';
import 'premium_card.dart';

class PremiumScreen extends ConsumerWidget {
  const PremiumScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = ref.watch(entitlementsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Premium')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Icon(
            Icons.workspace_premium_rounded,
            size: 56,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            plan.isPremium ? 'FutBeat Premium activo' : 'FutBeat Premium',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),
          const Text(
            'Disfruta FutBeat sin anuncios. Tus partidos, favoritos y Match Center siguen disponibles en el plan Gratis.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          const PremiumCard(),
        ],
      ),
    );
  }
}

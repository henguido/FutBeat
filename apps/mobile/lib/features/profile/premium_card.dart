import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/billing.dart';
import '../../core/entitlements.dart';

const premiumMessages = {
  PremiumActionResult.premium: 'Premium activo.',
  PremiumActionResult.pending: 'Pago pendiente de confirmación.',
  PremiumActionResult.cancelled: 'Compra cancelada.',
  PremiumActionResult.failed: 'No se pudo completar la compra.',
  PremiumActionResult.unavailable: 'Google Play no está disponible.',
  PremiumActionResult.nothingToRestore: 'No hay compras para restaurar.',
};

/// Current plan plus "Hazte Premium" / "Restaurar compras". The plan comes
/// only from [entitlementsProvider].
class PremiumCard extends ConsumerWidget {
  const PremiumCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = ref.watch(entitlementsProvider);
    final billing = ref.watch(premiumBillingProvider);
    final controller = ref.read(premiumBillingProvider.notifier);
    final enabled = controller.enabled;

    void show(PremiumActionResult result) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(premiumMessages[result]!)));
    }

    Future<void> upgrade() async {
      List<PremiumOffer> offers;
      try {
        offers = await controller.offers();
      } catch (_) {
        show(PremiumActionResult.unavailable);
        return;
      }
      if (!context.mounted) return;
      if (offers.isEmpty) {
        show(PremiumActionResult.unavailable);
        return;
      }
      final offer = await showModalBottomSheet<PremiumOffer>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final offer in offers)
                ListTile(
                  key: ValueKey('premium-offer-${offer.productId}'),
                  title: Text(
                    offer.period == PremiumPeriod.yearly ? 'Anual' : 'Mensual',
                  ),
                  trailing: Text(offer.price),
                  onTap: () => Navigator.of(context).pop(offer),
                ),
            ],
          ),
        ),
      );
      if (offer == null) return;
      show(await controller.buy(offer));
    }

    return Card(
      key: const ValueKey('premium-card'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Tu plan',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                Text(
                  plan.isPremium ? 'Premium' : 'Gratis',
                  key: const ValueKey('premium-plan'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              plan.isPremium
                  ? 'Sin anuncios.'
                  : 'Incluye todo, con anuncios. Premium los quita.',
            ),
            if (billing.pending) ...[
              const SizedBox(height: 4),
              Text(premiumMessages[PremiumActionResult.pending]!),
            ],
            if (enabled) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  if (!plan.isPremium)
                    FilledButton(
                      key: const ValueKey('premium-upgrade'),
                      onPressed: billing.busy ? null : upgrade,
                      child: const Text('Hazte Premium'),
                    ),
                  TextButton(
                    key: const ValueKey('premium-restore'),
                    onPressed: billing.busy
                        ? null
                        : () async => show(await controller.restore()),
                    child: const Text('Restaurar compras'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

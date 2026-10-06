import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/countries.dart';
import '../../core/database.dart';
import '../../core/interests.dart';
import '../../core/providers.dart';
import '../../core/push.dart';
import '../onboarding/onboarding_screen.dart';
import 'competition_order_preferences.dart';
import 'profile_screen.dart';
import 'profile_section.dart';

class PersonalizationScreen extends ConsumerWidget {
  const PersonalizationScreen({super.key});

  Future<void> _country(
    BuildContext context,
    WidgetRef ref,
    CountryPreference current,
  ) async {
    final code = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => CountryPickerSheet(current: current.selectedCountry),
    );
    if (code == null || code == current.selectedCountry) return;
    await ref
        .read(databaseProvider)
        .savePreference(
          detectedCountry: current.detectedCountry,
          selectedCountry: code,
          bootstrapDismissed: current.bootstrapDismissed,
          competitionOrderMode: current.competitionOrderMode,
          competitionOrderPreference: current.competitionOrderPreference,
          pinnedCompetitionIds: current.pinnedCompetitionIds,
        );
    final service = ref.read(pushServiceProvider);
    if (service.authenticated) {
      try {
        await service.syncCountries(current.detectedCountry, code);
      } catch (_) {}
    }
  }

  Future<void> _reenter(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rehacer configuración inicial'),
        content: const Text(
          'Podrás editar país, favoritos y alertas. Tus preferencias actuales no se borrarán.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continuar'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) context.push('/onboarding?reentry=1');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preference = ref.watch(preferenceProvider).asData?.value;
    final settings = ref.watch(profileSettingsProvider).asData?.value;
    final follows =
        ref.watch(followsProvider).asData?.value ?? const <String>{};
    int count(String type) =>
        follows.where((v) => v.startsWith('$type:')).length;
    if (preference == null || settings == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Personalización')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final country = preference.effectiveCountry;
    return Scaffold(
      appBar: AppBar(title: const Text('Personalización')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          ProfileSection(
            title: 'Preferencias',
            children: [
              ProfileDestinationTile(
                icon: Icons.public,
                title: 'País',
                subtitle: countryDisplayName(country) ?? 'Sin elegir',
                onTap: () => _country(context, ref, preference),
              ),
              ProfileDestinationTile(
                icon: Icons.star_outline,
                title: 'Mis favoritos',
                subtitle: favoritesSummary(
                  teams: count('team'),
                  competitions: count('competition'),
                  players: count('player'),
                ),
                onTap: () => context.push('/favorites'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const CompetitionOrderPanel(),
          ProfileSection(
            title: 'Formato de hora',
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: DropdownButtonFormField<String>(
                  key: const ValueKey('hour-format'),
                  initialValue: settings.hourFormat,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    labelText: 'Formato de hora',
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'system',
                      child: Text('Según el dispositivo'),
                    ),
                    DropdownMenuItem(value: '12h', child: Text('12 horas')),
                    DropdownMenuItem(value: '24h', child: Text('24 horas')),
                  ],
                  onChanged: (value) async {
                    if (value == null) return;
                    await ref
                        .read(pushServiceProvider)
                        .saveProfileSettings(
                          settings.copyWith(hourFormat: value),
                        );
                    ref.invalidate(profileSettingsProvider);
                  },
                ),
              ),
            ],
          ),
          ProfileSection(
            title: 'Configuración inicial',
            children: [
              ProfileDestinationTile(
                key: const ValueKey('redo-onboarding'),
                icon: Icons.restart_alt,
                title: 'Rehacer configuración inicial',
                subtitle: 'Vuelve a elegir país, favoritos y alertas paso a paso. No borra tus preferencias.',
                onTap: () => _reenter(context),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

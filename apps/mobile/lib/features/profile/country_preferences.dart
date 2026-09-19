import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/interests.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/push.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';

const supportedCountryChoices = <String?>[
  null,
  'CR',
  'MX',
  'AR',
  'BR',
  'ES',
  'US',
  'GB',
];

class CountryPreferencePanel extends ConsumerWidget {
  const CountryPreferencePanel({super.key, this.compact = false, this.data});
  final bool compact;
  final Snapshot? data;

  Future<void> selectCountry(
    BuildContext context,
    WidgetRef ref,
    String? value,
  ) async {
    final database = ref.read(databaseProvider);
    final current = await database.watchPreference().first;
    await database.savePreference(
      detectedCountry: current.detectedCountry,
      selectedCountry: value,
      bootstrapDismissed: compact ? true : current.bootstrapDismissed,
    );
    await ref
        .read(pushServiceProvider)
        .syncCountries(current.detectedCountry, value);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preference = ref.watch(preferenceProvider);
    return preference.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (value) {
        if (compact && value.bootstrapDismissed) {
          return const SizedBox.shrink();
        }
        final country = value.effectiveCountry;
        final available = country == 'CR';
        return Card(
          color: const Color(0xFF141D21),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Tu país',
                  style: TextStyle(
                    color: muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  countryName(country),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  isExpanded: true,
                  initialValue: value.selectedCountry,
                  decoration: const InputDecoration(labelText: 'Cambiar país'),
                  items: [
                    for (final code in supportedCountryChoices)
                      DropdownMenuItem(
                        value: code,
                        child: Text(
                          code == null
                              ? 'Usar región del dispositivo'
                              : countryName(code),
                        ),
                      ),
                  ],
                  onChanged: (country) => selectCountry(context, ref, country),
                ),
                if (compact && data != null && available) ...[
                  const SizedBox(height: 12),
                  for (final competition in data!.competitions.where(
                    (item) => item.country == 'Costa Rica',
                  ))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(
                        Icons.emoji_events_outlined,
                        color: lime,
                      ),
                      title: Text(competition.name),
                      trailing: FollowButton('competition', competition.id),
                      onTap: () =>
                          context.push('/competition/${competition.id}'),
                    ),
                  SizedBox(
                    height: 42,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final team in data!.teams.where(
                          (item) => item.country == 'Costa Rica',
                        ))
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ActionChip(
                              avatar: const Icon(Icons.add, size: 16),
                              label: Text('Seguir ${team.name}'),
                              onPressed: () async {
                                await ref
                                    .read(databaseProvider)
                                    .toggle('team', team.id);
                                ref.invalidate(followsProvider);
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  children: [
                    TextButton.icon(
                      onPressed: () => context.go('/explore'),
                      icon: const Icon(Icons.search),
                      label: const Text('Buscar equipos y ligas'),
                    ),
                    if (compact)
                      TextButton(
                        onPressed: () => ref
                            .read(databaseProvider)
                            .savePreference(
                              detectedCountry: value.detectedCountry,
                              selectedCountry: value.selectedCountry,
                              bootstrapDismissed: true,
                            ),
                        child: const Text('Continuar'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

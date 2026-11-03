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
    // Capture provider-owned objects before awaiting the modal/save: the
    // screen can be dismissed while the local preference is being written.
    final database = ref.read(databaseProvider);
    final service = ref.read(pushServiceProvider);
    final code = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => CountryPickerSheet(current: current.selectedCountry),
    );
    if (code == null) return;
    // Do not replay the snapshot captured when the modal opened: order,
    // pinned competitions or the detected region may have changed since.
    await database.saveSelectedCountry(code);
    await service.markSelectedCountryDirty();
    if (service.authenticated) {
      try {
        await service.syncCountries(
          current.detectedCountry,
          code,
          updateDetected: false,
        );
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
    final preferenceState = ref.watch(preferenceProvider);
    final preference = preferenceState.asData?.value;
    final settingsState = ref.watch(profileSettingsProvider);
    final settings = settingsState.asData?.value;
    final follows =
        ref.watch(followsProvider).asData?.value ?? const <String>{};
    int count(String type) =>
        follows.where((v) => v.startsWith('$type:')).length;
    if (preference == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Personalizar FutBeat')),
        body: Center(
          child: preferenceState.hasError
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('No pudimos leer tus preferencias.'),
                    TextButton(
                      onPressed: () => ref.invalidate(preferenceProvider),
                      child: const Text('Reintentar'),
                    ),
                  ],
                )
              : const CircularProgressIndicator(),
        ),
      );
    }
    final country = preference.effectiveCountry;
    return Scaffold(
      appBar: AppBar(title: const Text('Personalizar FutBeat')),
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
              ProfileDestinationTile(
                key: const ValueKey('personalize-teams'),
                icon: Icons.shield_outlined,
                title: 'Seguir equipos',
                subtitle: 'Busca equipos y cambia tus favoritos',
                onTap: () => context.push('/explore?type=team'),
              ),
              ProfileDestinationTile(
                key: const ValueKey('personalize-competitions'),
                icon: Icons.emoji_events_outlined,
                title: 'Seguir competiciones',
                subtitle: 'Busca ligas y cambia tus favoritos',
                onTap: () => context.push('/explore?type=competition'),
              ),
              ProfileDestinationTile(
                key: const ValueKey('personalize-players'),
                icon: Icons.person_search_outlined,
                title: 'Seguir jugadores',
                subtitle: 'Busca futbolistas del catálogo',
                onTap: () => context.push('/explore?type=player'),
              ),
              ProfileDestinationTile(
                key: const ValueKey('personalize-alerts'),
                icon: Icons.notifications_none,
                title: 'Alertas',
                subtitle: 'Revisa tus preferencias de notificaciones',
                onTap: () => context.push('/profile/notifications'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const CompetitionOrderPanel(),
          ProfileSection(
            title: 'Formato de hora',
            children: [
              // Hour-format settings are independent of local interests. A
              // delayed/failed read must not lock country/follow navigation.
              if (settings == null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: settingsState.hasError
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('No pudimos cargar el formato de hora.'),
                            TextButton(
                              key: const ValueKey('retry-hour-format'),
                              onPressed: () =>
                                  ref.invalidate(profileSettingsProvider),
                              child: const Text('Reintentar'),
                            ),
                          ],
                        )
                      : const LinearProgressIndicator(
                          key: ValueKey('hour-format-loading'),
                        ),
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _HourFormatPreference(
                    key: const ValueKey('hour-format'),
                    settings: settings,
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

class _HourFormatPreference extends ConsumerStatefulWidget {
  const _HourFormatPreference({super.key, required this.settings});
  final UserProfileSettings settings;

  @override
  ConsumerState<_HourFormatPreference> createState() =>
      _HourFormatPreferenceState();
}

class _HourFormatPreferenceState extends ConsumerState<_HourFormatPreference> {
  final _field = GlobalKey<FormFieldState<String>>();
  bool _restoring = false;

  Future<void> _save(String? value) async {
    if (value == null || _restoring) return;
    final service = ref.read(pushServiceProvider);
    try {
      await service.saveProfileSettings(
        widget.settings.copyWith(hourFormat: value),
      );
    } catch (_) {
      // Account sync may fail after the preference was saved locally.
      final UserProfileSettings local;
      try {
        local = await service.loadProfileSettings();
      } catch (_) {
        if (!mounted) return;
        _restoring = true;
        try {
          _field.currentState?.didChange(widget.settings.hourFormat);
        } finally {
          _restoring = false;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No pudimos comprobar el cambio. Inténtalo nuevamente.',
            ),
          ),
        );
        return;
      }
      if (!mounted) return;
      _restoring = true;
      try {
        _field.currentState?.didChange(local.hourFormat);
      } finally {
        _restoring = false;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            local.hourFormat == value
                ? 'Guardado en este dispositivo. Se sincronizará cuando haya conexión.'
                : 'No pudimos guardar este cambio. Inténtalo nuevamente.',
          ),
        ),
      );
    }
    if (mounted) ref.invalidate(profileSettingsProvider);
  }

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
    key: _field,
    isExpanded: true,
    initialValue: widget.settings.hourFormat,
    decoration: const InputDecoration(
      border: InputBorder.none,
      labelText: 'Formato de hora',
    ),
    items: const [
      DropdownMenuItem(value: 'system', child: Text('Según el dispositivo')),
      DropdownMenuItem(value: '12h', child: Text('12 horas')),
      DropdownMenuItem(value: '24h', child: Text('24 horas')),
    ],
    onChanged: _save,
  );
}

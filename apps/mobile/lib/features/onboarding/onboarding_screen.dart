import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/countries.dart';
import '../../core/database.dart';
import '../../core/interests.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/push.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';

const onboardingStepCount = 6;

bool isSelectableCountryCode(String? value) =>
    value != null && RegExp(r'^[A-Z]{2}$').hasMatch(value);

/// Country shown in onboarding: only the user's own choice. The device
/// locale is not a location, so it never pre-fills the selector. Unknown
/// codes are never shown raw.
String? onboardingCountryCode(CountryPreference preference) {
  final code = preference.selectedCountry;
  return countryDisplayName(code) == null ? null : code!.trim().toUpperCase();
}

bool isCurrentOnboardingRequest(
  ({String query, String? country}) request, {
  required String currentQuery,
  required String? currentCountry,
}) => request.query == currentQuery && request.country == currentCountry;

List<Entity> rankOnboardingEntities(
  Iterable<Entity> entities,
  String? country,
) {
  final normalized = country?.trim().toUpperCase();
  final result = entities.toList();
  result.sort((a, b) {
    int score(Entity entity) {
      final code = entity.json['countryCode']?.toString().toUpperCase();
      final value = entity.country.toUpperCase();
      final local =
          normalized != null &&
          (code == normalized ||
              value == normalized ||
              code?.startsWith('$normalized-') == true);
      final relevance = (entity.json['relevanceScore'] as num?)?.toInt() ?? 0;
      final global =
          entity.json['globalRelevant'] == true ||
          entity.json['isGlobalRelevant'] == true;
      return (local ? 100000 : 0) + (global ? 10000 : 0) + relevance;
    }

    final byScore = score(b).compareTo(score(a));
    return byScore != 0 ? byScore : a.name.compareTo(b.name);
  });
  return result;
}

List<Entity> onboardingEntitiesForQuery(
  Iterable<Entity> entities,
  String? country,
  String query,
) {
  final ordered = query.trim().length >= 2
      ? entities.toList()
      : rankOnboardingEntities(entities, country);
  return ordered.take(30).toList();
}

Future<bool> saveOnboardingSettings({
  required UserProfileSettings settings,
  required Future<void> Function(UserProfileSettings) save,
  required void Function() invalidate,
}) async {
  try {
    await save(settings);
    return true;
  } catch (_) {
    return false;
  } finally {
    invalidate();
  }
}

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key, this.reentry = false});
  final bool reentry;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  int step = 0;
  String query = '';
  Timer? debounce;
  Timer? remoteRetry;
  ({String query, String? country})? remoteRetryRequest;
  ({String query, String? country})? lastRetryRequest;
  int remoteAttempts = 0;
  String pendingQuery = '';
  final searchController = TextEditingController();
  UserProfileSettings? settings;
  bool busy = false;
  bool settingsBusy = false;
  bool countryBusy = false;
  String? message;

  @override
  void dispose() {
    debounce?.cancel();
    remoteRetry?.cancel();
    remoteRetryRequest = null;
    lastRetryRequest = null;
    searchController.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await ref.read(databaseProvider).markBootstrapDismissed();
    } finally {
      if (mounted) context.go('/matches');
    }
  }

  void _next() {
    FocusScope.of(context).unfocus();
    debounce?.cancel();
    remoteRetry?.cancel();
    remoteRetry = null;
    remoteRetryRequest = null;
    lastRetryRequest = null;
    remoteAttempts = 0;
    pendingQuery = '';
    searchController.clear();
    if (step == onboardingStepCount - 1) {
      _finish();
    } else {
      setState(() {
        step++;
        query = '';
      });
    }
  }

  void _back() {
    FocusScope.of(context).unfocus();
    debounce?.cancel();
    remoteRetry?.cancel();
    remoteRetry = null;
    remoteRetryRequest = null;
    lastRetryRequest = null;
    remoteAttempts = 0;
    pendingQuery = '';
    searchController.clear();
    if (step > 0) {
      setState(() {
        step--;
        query = '';
      });
    }
  }

  void _search(String value) {
    pendingQuery = value.trim();
    debounce?.cancel();
    remoteRetry?.cancel();
    remoteRetry = null;
    remoteRetryRequest = null;
    lastRetryRequest = null;
    remoteAttempts = 0;
    debounce = Timer(const Duration(milliseconds: 275), () {
      if (mounted) setState(() => query = value.trim());
    });
  }

  Future<void> _toggle(String type, String id) async {
    await ref.read(databaseProvider).toggle(type, id);
  }

  Future<void> _saveSettings(UserProfileSettings next) async {
    if (settingsBusy) return;
    setState(() {
      settings = next;
      settingsBusy = true;
      message = null;
    });
    final saved = await saveOnboardingSettings(
      settings: next,
      save: ref.read(pushServiceProvider).saveProfileSettings,
      invalidate: () {
        if (mounted) ref.invalidate(profileSettingsProvider);
      },
    );
    if (mounted) {
      setState(() {
        settingsBusy = false;
        if (!saved) {
          message = 'Guardado sin conexión';
        }
      });
    }
  }

  void _scheduleRemoteRetry(({String query, String? country}) request) {
    const delays = [
      Duration(seconds: 3),
      Duration(seconds: 5),
      Duration(seconds: 8),
    ];
    final currentCountry = ref
        .read(preferenceProvider)
        .asData
        ?.value
        .effectiveCountry;
    if (!mounted ||
        step != 3 ||
        !isCurrentOnboardingRequest(
          request,
          currentQuery: pendingQuery,
          currentCountry: currentCountry,
        )) {
      return;
    }
    if (lastRetryRequest != request) {
      remoteRetry?.cancel();
      remoteRetry = null;
      remoteRetryRequest = null;
      remoteAttempts = 0;
      lastRetryRequest = request;
    }
    if (remoteRetry != null && remoteRetryRequest != request) {
      remoteRetry?.cancel();
      remoteRetry = null;
      remoteAttempts = 0;
    }
    if (remoteRetry != null || remoteAttempts >= delays.length) return;
    remoteRetryRequest = request;
    remoteRetry = Timer(delays[remoteAttempts], () {
      final latestCountry = mounted
          ? ref.read(preferenceProvider).asData?.value.effectiveCountry
          : null;
      if (!mounted ||
          step != 3 ||
          !isCurrentOnboardingRequest(
            request,
            currentQuery: pendingQuery,
            currentCountry: latestCountry,
          )) {
        remoteRetry = null;
        remoteRetryRequest = null;
        lastRetryRequest = null;
        remoteAttempts = 0;
        return;
      }
      setState(() {
        remoteAttempts++;
        remoteRetry = null;
        remoteRetryRequest = null;
      });
      ref.invalidate(searchSnapshotProvider(request));
    });
  }

  Future<void> _selectCountry(String? value) async {
    if (countryBusy) return;
    setState(() => countryBusy = true);
    // Capture provider-owned objects before the first await. The route can be
    // dismissed while Drift is saving, after which WidgetRef is no longer safe.
    final database = ref.read(databaseProvider);
    final service = ref.read(pushServiceProvider);
    await database.saveSelectedCountry(value);
    final current = await database.watchPreference().first;
    await service.markSelectedCountryDirty();
    if (service.authenticated) {
      try {
        await service.syncCountries(
          current.detectedCountry,
          value,
          updateDetected: false,
        );
      } catch (_) {
        // Drift remains authoritative offline; the normal reconcile can retry.
      }
    }
    if (mounted) setState(() => countryBusy = false);
  }

  Future<void> _openProfile() async {
    await ref.read(databaseProvider).markBootstrapDismissed();
    if (mounted) context.push('/profile');
  }

  @override
  Widget build(BuildContext context) {
    final preference = ref.watch(preferenceProvider).asData?.value;
    final follows =
        ref.watch(followsProvider).asData?.value ?? const <String>{};
    final catalogState = ref.watch(exploreSnapshotProvider);
    final catalog = catalogState.asData?.value;
    final country = preference?.effectiveCountry;
    final searchRequest = (query: query, country: country);
    final searchState = query.length >= 2 && const {1, 2, 3}.contains(step)
        ? ref.watch(searchSnapshotProvider(searchRequest))
        : null;
    if (step == 3 && searchState != null) {
      ref.listen(searchSnapshotProvider(searchRequest), (_, next) {
        if (!next.isLoading && next.asData?.value.pendingRemote == true) {
          _scheduleRemoteRetry(searchRequest);
        }
      });
    }
    final data = searchState?.asData?.value ?? catalog;
    settings ??= ref.watch(profileSettingsProvider).asData?.value;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(
          widget.reentry ? 'Personalizar FutBeat' : 'Bienvenido a FutBeat',
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : _finish,
            child: const Text('Saltar'),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(
            value: (step + 1) / onboardingStepCount,
            minHeight: 4,
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              children: [
                Text(
                  _title,
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 18),
                if (step == 0) _countryStep(preference),
                if (step == 1)
                  _entityStep('team', data, follows, catalogState, searchState),
                if (step == 2)
                  _entityStep(
                    'competition',
                    data,
                    follows,
                    catalogState,
                    searchState,
                  ),
                if (step == 3)
                  _playerStep(data, follows, catalogState, searchState),
                if (step == 4) _alertsStep(),
                if (step == 5) _accountStep(),
                if (message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(message!, style: const TextStyle(color: muted)),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            minimum: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Row(
              children: [
                if (step > 0)
                  OutlinedButton(
                    onPressed: busy ? null : _back,
                    child: const Text('Atrás'),
                  ),
                if (step > 0) const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: busy ? null : _next,
                    child: Text(
                      step == onboardingStepCount - 1
                          ? 'Ir a Partidos'
                          : 'Continuar',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String get _title => const [
    'País',
    'Equipos',
    'Competiciones',
    'Jugadores',
    'Alertas',
    'Cuenta',
  ][step];

  Widget _countryStep(CountryPreference? preference) {
    if (preference == null) return const LinearProgressIndicator();
    final code = onboardingCountryCode(preference);
    final name = countryDisplayName(code);
    final flag = countryFlag(code);
    return InkWell(
      key: const ValueKey('onboarding-country'),
      borderRadius: BorderRadius.circular(12),
      onTap: countryBusy ? null : () => _pickCountry(code),
      child: InputDecorator(
        decoration: const InputDecoration(labelText: 'País'),
        child: Row(
          children: [
            if (flag != null) ...[
              Text(flag, style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                name ?? 'Elegir país',
                key: const ValueKey('onboarding-country-name'),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              name == null ? '' : 'Cambiar',
              style: const TextStyle(color: lime, fontWeight: FontWeight.w700),
            ),
            const Icon(Icons.expand_more_rounded),
          ],
        ),
      ),
    );
  }

  Future<void> _pickCountry(String? current) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => CountryPickerSheet(current: current),
    );
    if (picked != null && picked != current) await _selectCountry(picked);
  }

  Widget _entityStep(
    String type,
    Snapshot? data,
    Set<String> follows,
    AsyncValue<Snapshot> catalogState,
    AsyncValue<Snapshot>? searchState,
  ) {
    final source = type == 'team'
        ? data?.teams ?? <Entity>[]
        : data?.competitions ?? <Entity>[];
    final country = ref.read(preferenceProvider).asData?.value.effectiveCountry;
    // Search is already ordered by match quality, country and relevance on the
    // backend. Only the unsearched Explore suggestions need local reranking.
    final entities = onboardingEntitiesForQuery(source, country, query);
    return Column(
      children: [
        TextField(
          controller: searchController,
          onChanged: _search,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: type == 'team'
                ? 'Buscar equipos'
                : 'Buscar competiciones',
          ),
        ),
        if (searchState?.isLoading == true)
          const LinearProgressIndicator(minHeight: 2),
        if ((searchState ?? catalogState).hasError)
          _catalogError(
            () => searchState == null
                ? ref.invalidate(exploreSnapshotProvider)
                : ref.invalidate(
                    searchSnapshotProvider((query: query, country: country)),
                  ),
          ),
        const SizedBox(height: 10),
        for (final entity in entities)
          _selectableEntity(
            entity,
            type,
            follows.contains('$type:${entity.id}'),
          ),
        if (entities.isEmpty && !(searchState ?? catalogState).isLoading)
          const Text('Sin sugerencias'),
      ],
    );
  }

  Widget _playerStep(
    Snapshot? data,
    Set<String> follows,
    AsyncValue<Snapshot> catalogState,
    AsyncValue<Snapshot>? searchState,
  ) {
    final selectedTeams = follows
        .where((item) => item.startsWith('team:'))
        .map((item) => item.substring(5))
        .toSet();
    final source = data?.players ?? <Entity>[];
    final players = query.length >= 2
        ? source
        : source
              .where(
                (player) =>
                    selectedTeams.contains(player.json['teamId']?.toString()),
              )
              .toList();
    return Column(
      children: [
        TextField(
          controller: searchController,
          onChanged: _search,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Buscar jugadores',
          ),
        ),
        if (searchState?.isLoading == true)
          const LinearProgressIndicator(minHeight: 2),
        if (data?.pendingRemote == true && remoteAttempts < 3)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Text('Buscando más jugadores…'),
          ),
        if ((searchState ?? catalogState).hasError)
          _catalogError(
            () => searchState == null
                ? ref.invalidate(exploreSnapshotProvider)
                : ref.invalidate(
                    searchSnapshotProvider((
                      query: query,
                      country: ref
                          .read(preferenceProvider)
                          .asData
                          ?.value
                          .effectiveCountry,
                    )),
                  ),
          ),
        const SizedBox(height: 10),
        for (final player in players.take(30))
          _selectableEntity(
            player,
            'player',
            follows.contains('player:${player.id}'),
          ),
        if (players.isEmpty && !(searchState ?? catalogState).isLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text('Sin resultados'),
          ),
      ],
    );
  }

  Widget _selectableEntity(
    Entity entity,
    String type,
    bool selected,
  ) => Semantics(
    button: true,
    selected: selected,
    label: '${entity.name}, ${selected ? 'seleccionado' : 'no seleccionado'}',
    excludeSemantics: true,
    child: Card(
      child: ListTile(
        minVerticalPadding: 10,
        leading: EntityAvatar(entity),
        title: Text(entity.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: entity.country.isEmpty ? null : Text(entity.country),
        trailing: Icon(
          selected ? Icons.check_circle : Icons.add_circle_outline,
          color: selected ? lime : muted,
        ),
        onTap: () => _toggle(type, entity.id),
      ),
    ),
  );

  Widget _catalogError(VoidCallback retry) => Card(
    child: ListTile(
      title: const Text('Sin conexión'),
      trailing: TextButton(onPressed: retry, child: const Text('Reintentar')),
    ),
  );

  Widget _alertsStep() {
    final value = settings;
    if (value == null) return const LinearProgressIndicator();
    final options = <(String, bool, UserProfileSettings Function(bool))>[
      (
        'Inicio de partido',
        value.notifyKickoff,
        (v) => value.copyWith(notifyKickoff: v),
      ),
      ('Goles', value.notifyGoals, (v) => value.copyWith(notifyGoals: v)),
      (
        'Resultado final',
        value.notifyFinal,
        (v) => value.copyWith(notifyFinal: v),
      ),
      ('Tarjetas', value.notifyCards, (v) => value.copyWith(notifyCards: v)),
      (
        'Alineaciones',
        value.notifyLineups,
        (v) => value.copyWith(notifyLineups: v),
      ),
      ('Noticias', value.notifyNews, (v) => value.copyWith(notifyNews: v)),
      (
        'Transferencias',
        value.notifyTransfers,
        (v) => value.copyWith(notifyTransfers: v),
      ),
    ];
    final any = options.any((item) => item.$2);
    final service = ref.watch(pushServiceProvider);
    return Column(
      children: [
        for (final item in options)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(item.$1),
            value: item.$2,
            onChanged: settingsBusy
                ? null
                : (next) => _saveSettings(item.$3(next)),
          ),
        const SizedBox(height: 8),
        if (service.authenticated && PushService.configured)
          FilledButton.tonalIcon(
            onPressed: !any || busy
                ? null
                : () async {
                    setState(() {
                      busy = true;
                      message = null;
                    });
                    try {
                      await service.enable();
                      if (!mounted) return;
                      setState(() => message = 'Notificaciones activadas');
                    } catch (_) {
                      if (!mounted) return;
                      setState(() => message = 'No se pudieron activar');
                    } finally {
                      if (mounted) setState(() => busy = false);
                    }
                  },
            icon: const Icon(Icons.notifications_active_outlined),
            label: const Text('Activar notificaciones'),
          )
        else
          const Text('Alertas guardadas'),
      ],
    );
  }

  Widget _accountStep() {
    final service = ref.watch(pushServiceProvider);
    if (!service.accountConfigured) {
      return const Text('Cuenta no disponible');
    }
    if (service.authenticated) {
      return Text(
        service.email == null
            ? 'Sesión iniciada'
            : 'Sesión iniciada · ${service.email}',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Opcional. Sin cuenta, tus favoritos se guardan en este dispositivo.',
          style: TextStyle(color: muted),
        ),
        const SizedBox(height: 12),
        FilledButton.tonal(
          onPressed: _openProfile,
          child: const Text('Crear cuenta'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _openProfile,
          child: const Text('Iniciar sesión'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: busy ? null : _finish,
          child: const Text('Continuar como invitado'),
        ),
      ],
    );
  }
}

/// Searchable list of every selectable country, localized names only.
class CountryPickerSheet extends StatefulWidget {
  const CountryPickerSheet({required this.current, super.key});

  final String? current;

  @override
  State<CountryPickerSheet> createState() => _CountryPickerSheetState();
}

class _CountryPickerSheetState extends State<CountryPickerSheet> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    final codes =
        selectableCountryCodes
            .where((code) => query.isEmpty || countryMatches(code, query))
            .toList()
          ..sort(
            (a, b) => countryDisplayName(a)!.compareTo(countryDisplayName(b)!),
          );
    return DraggableScrollableSheet(
      key: const ValueKey('country-picker'),
      expand: false,
      initialChildSize: .8,
      maxChildSize: .95,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              key: const ValueKey('country-picker-search'),
              autofocus: false,
              onChanged: (value) => setState(() => query = value),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Buscar país',
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: controller,
              itemCount: codes.length,
              itemBuilder: (context, index) {
                final code = codes[index];
                final selected = code == widget.current;
                return ListTile(
                  key: ValueKey('country-$code'),
                  leading: Text(
                    countryFlag(code) ?? '',
                    style: const TextStyle(fontSize: 22),
                  ),
                  title: Text(countryDisplayName(code)!),
                  trailing: selected
                      ? const Icon(Icons.check_rounded, color: lime)
                      : null,
                  onTap: () => Navigator.of(context).pop(code),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

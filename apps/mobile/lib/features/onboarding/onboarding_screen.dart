import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/database.dart';
import '../../core/interests.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/push.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';

const onboardingStepCount = 6;
const _automaticCountry = '__automatic__';

bool isSelectableCountryCode(String? value) =>
    value != null && RegExp(r'^[A-Z]{2}$').hasMatch(value);

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
  int remoteAttempts = 0;
  final searchController = TextEditingController();
  UserProfileSettings? settings;
  bool busy = false;
  bool settingsBusy = false;
  String? message;

  @override
  void dispose() {
    debounce?.cancel();
    remoteRetry?.cancel();
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
    remoteAttempts = 0;
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
    remoteAttempts = 0;
    searchController.clear();
    if (step > 0) {
      setState(() {
        step--;
        query = '';
      });
    }
  }

  void _search(String value) {
    debounce?.cancel();
    remoteRetry?.cancel();
    remoteRetry = null;
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
          message =
              'Guardado en este dispositivo. Se sincronizará al reconectar.';
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
    if (remoteRetry != null || remoteAttempts >= delays.length) return;
    remoteRetry = Timer(delays[remoteAttempts], () {
      if (!mounted || step != 3) return;
      setState(() {
        remoteAttempts++;
        remoteRetry = null;
      });
      ref.invalidate(searchSnapshotProvider(request));
    });
  }

  Future<void> _selectCountry(
    CountryPreference preference,
    String? value,
  ) async {
    await ref
        .read(databaseProvider)
        .savePreference(
          detectedCountry: preference.detectedCountry,
          selectedCountry: value,
          bootstrapDismissed: preference.bootstrapDismissed,
        );
    final service = ref.read(pushServiceProvider);
    await service.markCountriesDirty();
    if (service.authenticated) {
      try {
        await service.syncCountries(preference.detectedCountry, value);
      } catch (_) {
        // Drift remains authoritative offline; the normal reconcile can retry.
      }
    }
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
                const SizedBox(height: 6),
                Text(_subtitle, style: const TextStyle(color: muted)),
                const SizedBox(height: 18),
                if (step == 0) _countryStep(preference, catalogState, catalog),
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
    'Tu fútbol, más cerca',
    'Elige tus equipos',
    'Sigue competiciones',
    'Jugadores favoritos',
    'Elige tus alertas',
    'Tu cuenta es opcional',
  ][step];

  String get _subtitle => const [
    'Usamos tu país para ordenar sugerencias, nunca para ocultar partidos.',
    'Puedes elegir varios o continuar sin seleccionar.',
    'Primero verás lo más relevante para ti.',
    'Busca un jugador o simplemente omite este paso.',
    'Guarda ahora tus preferencias. El permiso se pide sólo si tú lo activas.',
    'Sincroniza favoritos y preferencias entre dispositivos.',
  ][step];

  Widget _countryStep(
    CountryPreference? preference,
    AsyncValue<Snapshot> state,
    Snapshot? catalog,
  ) {
    if (preference == null) return const LinearProgressIndicator();
    final labels = <String, String>{};
    String displayName(String code) {
      final fallback = countryName(code);
      return labels[code] ?? (fallback == 'Global' ? code : fallback);
    }

    for (final entity in [...?catalog?.competitions, ...?catalog?.teams]) {
      final code = entity.json['countryCode']?.toString().trim().toUpperCase();
      if (isSelectableCountryCode(code)) {
        final countryCode = code!;
        labels.putIfAbsent(
          countryCode,
          () => entity.country.isEmpty ? countryCode : entity.country,
        );
      }
    }
    final current = preference.selectedCountry;
    if (current != null) {
      labels.putIfAbsent(current, () => displayName(current));
    }
    final detected = preference.detectedCountry;
    if (detected != null) {
      labels.putIfAbsent(detected, () => displayName(detected));
    }
    final entries = labels.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (detected != null) Text('Detectado: ${displayName(detected)}'),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey(current ?? _automaticCountry),
          initialValue: current ?? _automaticCountry,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'País (opcional)'),
          items: [
            DropdownMenuItem(
              value: _automaticCountry,
              child: Text(
                detected == null
                    ? 'Automático'
                    : 'Automático (${displayName(detected)})',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            ...entries.map(
              (entry) => DropdownMenuItem(
                value: entry.key,
                child: Text(entry.value, overflow: TextOverflow.ellipsis),
              ),
            ),
          ],
          onChanged: (value) => _selectCountry(
            preference,
            value == _automaticCountry ? null : value,
          ),
        ),
        if (state.hasError)
          _catalogError(() => ref.invalidate(exploreSnapshotProvider)),
        if (state.isLoading)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: LinearProgressIndicator(),
          ),
      ],
    );
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
          const Text('No hay sugerencias disponibles. Puedes continuar.'),
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
            child: Text(
              'Busca por nombre. No mostramos sugerencias inventadas.',
            ),
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
      title: const Text('No pudimos cargar las sugerencias'),
      subtitle: const Text('Puedes reintentar o continuar sin conexión.'),
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
                      setState(() => message = 'Notificaciones activadas.');
                    } catch (_) {
                      if (!mounted) return;
                      setState(
                        () => message =
                            'No se pudieron activar. Puedes continuar.',
                      );
                    } finally {
                      if (mounted) setState(() => busy = false);
                    }
                  },
            icon: const Icon(Icons.notifications_active_outlined),
            label: const Text('Activar notificaciones'),
          )
        else
          const Text(
            'Tus preferencias quedan guardadas. Podrás activar avisos del sistema después de iniciar sesión.',
          ),
      ],
    );
  }

  Widget _accountStep() {
    final service = ref.watch(pushServiceProvider);
    if (!service.accountConfigured) {
      return const Text(
        'Puedes continuar como invitado. La cuenta no está configurada en esta instalación.',
      );
    }
    if (service.authenticated) {
      return Text(
        'Sesión iniciada${service.email == null ? '' : ' como ${service.email}'}. Tus selecciones se sincronizan con el flujo existente.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.tonal(
          onPressed: _openProfile,
          child: const Text('Crear cuenta'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _openProfile,
          child: const Text('Iniciar sesión'),
        ),
        const SizedBox(height: 10),
        const Text(
          'También puedes continuar sin cuenta.',
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

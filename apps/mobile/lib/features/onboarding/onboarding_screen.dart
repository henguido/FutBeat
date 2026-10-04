import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';

import '../../core/entitlements.dart' show currentAccountProvider;
import '../../core/countries.dart';
import '../../core/database.dart';
import '../../core/interests.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/push.dart';
import '../../core/relevance.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';
import '../profile/notification_options.dart';

/// Onboarding steps (#107): welcome → country → teams → competitions →
/// players → alerts → optional account → summary.
abstract final class OnboardingStep {
  static const welcome = 0;
  static const country = 1;
  static const teams = 2;
  static const competitions = 3;
  static const players = 4;
  static const alerts = 5;
  static const account = 6;
  static const summary = 7;
}

const onboardingStepCount = 8;

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

/// Unsearched suggestions, in the Partidos country-aware order: competitions
/// use [sortCompetitionsByFeedPriority] (primary domestic league, then big
/// global competitions, then secondary national ones, then the rest) and
/// teams [rankCountryTeams]. Follows are deliberately not lifted here, so a
/// row never jumps while the user is selecting it. [competition] resolves a
/// team's competition from the same catalog.
List<Entity> rankOnboardingEntities(
  String type,
  Iterable<Entity> entities,
  String? country, {
  Entity? Function(String id)? competition,
}) => type == 'team'
    ? rankCountryTeams(
        entities,
        userCountry: country,
        competitions: competition,
      )
    : sortCompetitionsByFeedPriority(
        entities,
        follows: const <String>{},
        userCountry: country,
      );

List<Entity> onboardingEntitiesForQuery(
  String type,
  Iterable<Entity> entities,
  String? country,
  String query, {
  Entity? Function(String id)? competition,
}) {
  final ordered = query.trim().length >= 2
      ? entities.toList()
      : rankOnboardingEntities(
          type,
          entities,
          country,
          competition: competition,
        );
  return ordered.take(30).toList();
}

/// Visible name of a suggestion. A national team flagged by the catalog uses
/// the localized name of its country code; everything else keeps its name
/// (the app-wide resolver, [teamDisplayName]).
String onboardingEntityName(Entity entity) => entity.displayName;

/// Spanish country/region subtitle; never a raw provider code, and omitted
/// when it would only repeat the title.
String? onboardingEntitySubtitle(Entity entity) {
  final label = entityCountryLabel(entity);
  return label == null || label == onboardingEntityName(entity) ? null : label;
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

/// Where a first-run onboarding resumes after the app is closed. Behind an
/// interface so tests use memory; failures only lose the resume point.
abstract interface class OnboardingProgressStore {
  Future<int?> read();
  Future<void> write(int step);
  Future<void> clear();
}

class SecureOnboardingProgressStore implements OnboardingProgressStore {
  const SecureOnboardingProgressStore();
  static const _key = 'futbeat.onboarding.step';
  static const _storage = FlutterSecureStorage();

  @override
  Future<int?> read() async {
    try {
      return int.tryParse(await _storage.read(key: _key) ?? '');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(int step) async {
    try {
      await _storage.write(key: _key, value: '$step');
    } catch (_) {}
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {}
  }
}

final onboardingProgressStoreProvider = Provider<OnboardingProgressStore>(
  (ref) => const SecureOnboardingProgressStore(),
);

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key, this.reentry = false});
  final bool reentry;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  int step = OnboardingStep.welcome;
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

  OnboardingProgressStore get _progress =>
      ref.read(onboardingProgressStoreProvider);

  @override
  void initState() {
    super.initState();
    // Re-entry (Perfil → Personalizar) starts at the country; a first run
    // resumes where it was left.
    if (widget.reentry) {
      step = OnboardingStep.country;
    } else {
      unawaited(_resume());
    }
  }

  Future<void> _resume() async {
    final saved = await _progress.read();
    if (!mounted || saved == null || step != OnboardingStep.welcome) return;
    if (saved > OnboardingStep.welcome && saved < onboardingStepCount) {
      setState(() => step = saved);
    }
  }

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
      unawaited(_progress.clear());
      await ref.read(databaseProvider).markBootstrapDismissed();
    } finally {
      if (mounted) context.go('/matches');
    }
  }

  void _resetSearch() {
    FocusScope.of(context).unfocus();
    debounce?.cancel();
    remoteRetry?.cancel();
    remoteRetry = null;
    remoteRetryRequest = null;
    lastRetryRequest = null;
    remoteAttempts = 0;
    pendingQuery = '';
    searchController.clear();
  }

  void _goTo(int next) {
    _resetSearch();
    setState(() {
      step = next;
      query = '';
      message = null;
    });
    if (!widget.reentry) unawaited(_progress.write(next));
  }

  void _next() {
    if (step == onboardingStepCount - 1) {
      _finish();
    } else {
      _goTo(step + 1);
    }
  }

  void _back() {
    final first = widget.reentry
        ? OnboardingStep.country
        : OnboardingStep.welcome;
    if (step > first) _goTo(step - 1);
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
    await toggleFollow(
      ref.read(databaseProvider),
      ref.read(entityMediaProvider).redirects,
      type,
      id,
    );
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
        step != OnboardingStep.players ||
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
          step != OnboardingStep.players ||
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

  /// Sign in / create the account in Perfil (one auth screen for the whole
  /// app); the onboarding updates by itself when the account changes.
  Future<void> _openProfile() async {
    if (mounted) await context.push('/profile');
  }

  static const _searchSteps = {
    OnboardingStep.teams,
    OnboardingStep.competitions,
    OnboardingStep.players,
  };

  @override
  Widget build(BuildContext context) {
    final preference = ref.watch(preferenceProvider).asData?.value;
    final follows =
        ref.watch(followsProvider).asData?.value ?? const <String>{};
    final catalogState = ref.watch(exploreSnapshotProvider);
    final rawCatalog = catalogState.asData?.value;
    final catalog = rawCatalog == null
        ? null
        : presentSnapshotForSession(ref, rawCatalog);
    final country = preference?.effectiveCountry;
    final searchRequest = (query: query, country: country);
    final searchState = query.length >= 2 && _searchSteps.contains(step)
        ? ref.watch(searchSnapshotProvider(searchRequest))
        : null;
    if (step == OnboardingStep.players && searchState != null) {
      ref.listen(searchSnapshotProvider(searchRequest), (_, next) {
        if (!next.isLoading && next.asData?.value.pendingRemote == true) {
          _scheduleRemoteRetry(searchRequest);
        }
      });
    }
    final rawSearch = searchState?.asData?.value;
    final data = rawSearch == null
        ? catalog
        : presentSnapshotForSession(ref, rawSearch);
    settings ??= ref.watch(profileSettingsProvider).asData?.value;

    final Widget content = switch (step) {
      OnboardingStep.welcome => _welcomeStep(),
      OnboardingStep.country => _countryStep(preference),
      OnboardingStep.teams => _entityStep(
        'team',
        data,
        follows,
        catalogState,
        searchState,
      ),
      OnboardingStep.competitions => _entityStep(
        'competition',
        data,
        follows,
        catalogState,
        searchState,
      ),
      OnboardingStep.players => _playerStep(
        data,
        follows,
        catalogState,
        searchState,
      ),
      OnboardingStep.alerts => _alertsStep(),
      OnboardingStep.account => _accountStep(),
      _ => _summaryStep(preference, follows),
    };

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            if (step != OnboardingStep.welcome) _header(),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween(
                      begin: const Offset(.04, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: KeyedSubtree(
                  key: ValueKey('onboarding-step-$step'),
                  child: step == OnboardingStep.welcome
                      ? content
                      : ListView(
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                          children: [
                            if (widget.reentry)
                              const Padding(
                                padding: EdgeInsets.only(bottom: 4),
                                child: Text(
                                  'Personalizar FutBeat',
                                  style: TextStyle(color: muted),
                                ),
                              ),
                            Text(
                              _title,
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w900),
                            ),
                            if (_subtitle case final subtitle?) ...[
                              const SizedBox(height: 6),
                              Text(
                                subtitle,
                                style: const TextStyle(color: muted),
                              ),
                            ],
                            const SizedBox(height: 18),
                            content,
                            if (message != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text(
                                  message!,
                                  style: const TextStyle(color: muted),
                                ),
                              ),
                          ],
                        ),
                ),
              ),
            ),
            if (step != OnboardingStep.welcome) _footer(),
          ],
        ),
      ),
    );
  }

  /// Back, discreet progress and Skip.
  Widget _header() {
    final first = widget.reentry
        ? OnboardingStep.country
        : OnboardingStep.welcome;
    final canSkip = step < OnboardingStep.summary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Atrás',
            onPressed: busy || step <= first ? null : _back,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                key: const ValueKey('onboarding-progress'),
                value: step / (onboardingStepCount - 1),
                minHeight: 4,
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (canSkip)
            TextButton(
              onPressed: busy ? null : _finish,
              child: const Text('Saltar'),
            )
          else
            const SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _footer() => SafeArea(
    top: false,
    minimum: const EdgeInsets.fromLTRB(20, 8, 20, 12),
    child: SizedBox(
      width: double.infinity,
      height: 52,
      child: FilledButton(
        key: const ValueKey('onboarding-next'),
        onPressed: busy ? null : _next,
        child: Text(
          step == onboardingStepCount - 1 ? 'Ir a Partidos' : 'Continuar',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
      ),
    ),
  );

  String get _title => switch (step) {
    OnboardingStep.country => 'País',
    OnboardingStep.teams => 'Equipos',
    OnboardingStep.competitions => 'Ligas',
    OnboardingStep.players => 'Jugadores',
    OnboardingStep.alerts => 'Alertas',
    OnboardingStep.account => 'Cuenta',
    _ => 'Todo listo',
  };

  String? get _subtitle => step == OnboardingStep.players ? 'Opcional.' : null;

  Widget _welcomeStep() => Padding(
    padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(flex: 3),
        Center(
          child: Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: lime.withValues(alpha: .12),
              shape: BoxShape.circle,
              border: Border.all(color: lime.withValues(alpha: .5), width: 2),
            ),
            child: const Icon(Icons.sports_soccer, color: lime, size: 54),
          ),
        ),
        const SizedBox(height: 24),
        const FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Fut',
                style: TextStyle(fontSize: 40, fontWeight: FontWeight.w900),
              ),
              Text(
                'Beat',
                style: TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.w900,
                  color: lime,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'EL LATIDO DEL FÚTBOL',
          textAlign: TextAlign.center,
          style: TextStyle(color: muted, fontSize: 12, letterSpacing: 3),
        ),
        const Spacer(flex: 4),
        SizedBox(
          height: 56,
          child: FilledButton(
            key: const ValueKey('onboarding-quick-setup'),
            onPressed: busy ? null : () => _goTo(OnboardingStep.country),
            child: const Text(
              'Configuración rápida',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
          ),
        ),
        const SizedBox(height: 10),
        if (ref.watch(pushServiceProvider).accountConfigured &&
            !ref.watch(pushServiceProvider).authenticated)
          SizedBox(
            height: 52,
            child: OutlinedButton(
              onPressed: busy ? null : _openProfile,
              child: const Text('Iniciar sesión'),
            ),
          ),
        TextButton(
          onPressed: busy ? null : _finish,
          child: const Text('Continuar como invitado'),
        ),
      ],
    ),
  );

  Widget _countryStep(CountryPreference? preference) {
    if (preference == null) return const LinearProgressIndicator();
    final code = onboardingCountryCode(preference);
    final name = countryDisplayName(code);
    final flag = countryFlag(code);
    return Material(
      color: panel,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        key: const ValueKey('onboarding-country'),
        borderRadius: BorderRadius.circular(20),
        onTap: countryBusy ? null : () => _pickCountry(code),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: name == null ? const Color(0xFF2B373D) : lime,
              width: name == null ? 1 : 2,
            ),
          ),
          child: Row(
            children: [
              Text(flag ?? '🌍', style: const TextStyle(fontSize: 44)),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  name ?? 'Elegir país',
                  key: const ValueKey('onboarding-country-name'),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                name == null ? '' : 'Cambiar',
                style: const TextStyle(
                  color: lime,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Icon(Icons.expand_more_rounded),
            ],
          ),
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

  Widget _searchField(String hint, int selected) => Row(
    children: [
      Expanded(
        child: TextField(
          controller: searchController,
          onChanged: _search,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: hint,
          ),
        ),
      ),
      const SizedBox(width: 10),
      AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected > 0 ? lime : panel,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          '$selected',
          key: const ValueKey('onboarding-selected-count'),
          style: TextStyle(
            fontWeight: FontWeight.w900,
            color: selected > 0 ? const Color(0xFF0B1114) : muted,
          ),
        ),
      ),
    ],
  );

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 8),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(color: muted, fontSize: 11, letterSpacing: 2),
    ),
  );

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
    final entities = onboardingEntitiesForQuery(
      type,
      source,
      country,
      query,
      competition: (id) => data?.competition(id),
    );
    final selected = follows.where((f) => f.startsWith('$type:')).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _searchField(
          type == 'team' ? 'Buscar equipos' : 'Buscar ligas',
          selected,
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
        if (query.length < 2 && entities.isNotEmpty)
          _sectionLabel(type == 'team' ? 'Sugeridos' : 'Recomendadas')
        else
          const SizedBox(height: 12),
        _grid([
          for (final entity in entities)
            _selectableEntity(
              entity,
              type,
              follows.contains('$type:${entity.id}'),
            ),
        ]),
        if (entities.isEmpty && !(searchState ?? catalogState).isLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text('Sin sugerencias', textAlign: TextAlign.center),
          ),
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
    final selected = follows.where((f) => f.startsWith('player:')).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _searchField('Buscar jugadores', selected),
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
        if (query.length < 2 && players.isNotEmpty)
          _sectionLabel('De tus equipos')
        else
          const SizedBox(height: 12),
        _grid([
          for (final player in players.take(30))
            _selectableEntity(
              player,
              'player',
              follows.contains('player:${player.id}'),
            ),
        ]),
        if (players.isEmpty && !(searchState ?? catalogState).isLoading)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Text(
              query.length >= 2 ? 'Sin resultados' : 'Busca a tus jugadores',
              textAlign: TextAlign.center,
              style: const TextStyle(color: muted),
            ),
          ),
      ],
    );
  }

  Widget _grid(List<Widget> tiles) => GridView.count(
    crossAxisCount: 3,
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    mainAxisSpacing: 10,
    crossAxisSpacing: 10,
    childAspectRatio: .78,
    children: tiles,
  );

  Widget _selectableEntity(Entity entity, String type, bool selected) {
    final name = onboardingEntityName(entity);
    final subtitle = onboardingEntitySubtitle(entity);
    return Semantics(
      button: true,
      selected: selected,
      label: '$name, ${selected ? 'seleccionado' : 'no seleccionado'}',
      excludeSemantics: true,
      child: Material(
        key: ValueKey('onboarding-$type-${entity.id}'),
        color: selected ? lime.withValues(alpha: .12) : panel,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _toggle(type, entity.id),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: selected ? lime : const Color(0xFF2B373D),
                width: selected ? 2 : 1,
              ),
            ),
            child: Stack(
              children: [
                Column(
                  children: [
                    EntityAvatar(entity, size: 54),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          height: 1.15,
                        ),
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: muted, fontSize: 11),
                      ),
                  ],
                ),
                Positioned(
                  top: -4,
                  right: -2,
                  child: Icon(
                    selected ? Icons.check_circle : Icons.add_circle_outline,
                    size: 20,
                    color: selected ? lime : muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _catalogError(VoidCallback retry) => Card(
    child: ListTile(
      title: const Text('Sin conexión'),
      trailing: TextButton(onPressed: retry, child: const Text('Reintentar')),
    ),
  );

  Widget _alertsStep() {
    final value = settings;
    if (value == null) return const LinearProgressIndicator();
    final any = value.anyNotification;
    final service = ref.watch(pushServiceProvider);
    return Column(
      children: [
        Material(
          color: panel,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Column(
              children: [
                for (final option in notificationOptions)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: Icon(option.icon, color: muted),
                    title: Text(option.title),
                    value: option.value(value),
                    onChanged: settingsBusy
                        ? null
                        : (next) => _saveSettings(option.update(value, next)),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        // The Android permission is only requested from here, after the
        // user picked what to be notified about.
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
          const Text('Alertas guardadas', style: TextStyle(color: muted)),
      ],
    );
  }

  Widget _accountStep() {
    // Rebuilds after signing in / creating the account from Perfil.
    ref.watch(currentAccountProvider);
    final service = ref.watch(pushServiceProvider);
    if (!service.accountConfigured) {
      return const Text('Cuenta no disponible');
    }
    if (service.authenticated) {
      return Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: lime.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: lime),
        ),
        child: Row(
          children: [
            const Icon(Icons.verified_user_outlined, color: lime),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                service.email == null
                    ? 'Sesión iniciada'
                    : 'Sesión iniciada · ${service.email}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Sincroniza favoritos, preferencias, notificaciones y Premium.',
          style: TextStyle(color: muted),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 52,
          child: FilledButton.tonal(
            onPressed: _openProfile,
            child: const Text('Crear cuenta'),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 52,
          child: OutlinedButton(
            onPressed: _openProfile,
            child: const Text('Iniciar sesión'),
          ),
        ),
        const SizedBox(height: 6),
        TextButton(
          onPressed: busy ? null : _next,
          child: const Text('Continuar sin cuenta'),
        ),
      ],
    );
  }

  Widget _summaryStep(CountryPreference? preference, Set<String> follows) {
    final code = preference == null ? null : onboardingCountryCode(preference);
    int count(String type) =>
        follows.where((f) => f.startsWith('$type:')).length;
    Widget tile(String key, String value, String label, {String? lead}) =>
        Container(
          key: ValueKey('onboarding-summary-$key'),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(
            color: panel,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              if (lead != null) ...[
                Text(lead, style: const TextStyle(fontSize: 26)),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(color: muted, fontSize: 15),
                ),
              ),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        );
    return Column(
      children: [
        tile(
          'country',
          countryDisplayName(code) ?? 'Sin elegir',
          'País',
          lead: countryFlag(code) ?? '🌍',
        ),
        const SizedBox(height: 10),
        tile('teams', '${count('team')}', 'Equipos'),
        const SizedBox(height: 10),
        tile('competitions', '${count('competition')}', 'Ligas'),
        const SizedBox(height: 10),
        tile('players', '${count('player')}', 'Jugadores'),
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

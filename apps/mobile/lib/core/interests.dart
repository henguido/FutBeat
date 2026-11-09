import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database.dart';
import 'providers.dart';
import 'push.dart';

String? normalizeCountry(String? value) {
  final country = value?.trim().toUpperCase();
  return country != null && RegExp(r'^[A-Z]{2}$').hasMatch(country)
      ? country
      : null;
}

String? _simCountry;

/// Reads the SIM / network country once at startup (Android). A phone in
/// Costa Rica with an es-US locale is in Costa Rica: the SIM is a better
/// region hint than the language setting. Needs no permission.
Future<void> loadDeviceRegion({bool? android}) async {
  _simCountry = null;
  if (!(android ?? Platform.isAndroid)) return;
  try {
    _simCountry = normalizeCountry(
      await const MethodChannel('futbeat/device')
          .invokeMethod<String>('simCountry'),
    );
  } catch (_) {
    // No telephony: the locale region is used.
  }
}

/// The device's region: SIM / network country, else the locale's region.
String? deviceCountry(String? localeCountry) =>
    _simCountry ?? normalizeCountry(localeCountry);

final detectedCountryProvider = Provider<String?>(
  (_) => deviceCountry(PlatformDispatcher.instance.locale.countryCode),
);

Future<CountryPreference> refreshDetectedCountry(
  AppDatabase database,
  String? detected,
) async {
  var current = await database.watchPreference().first;
  if (current.detectedCountry != detected) {
    await database.saveDetectedCountry(detected);
    current = await database.watchPreference().first;
  }
  return current;
}

final preferenceProvider = StreamProvider<CountryPreference>((ref) async* {
  final database = ref.watch(databaseProvider);
  final detected = ref.watch(detectedCountryProvider);
  var current = await database.watchPreference().first;
  if (current.detectedCountry != detected && ref.mounted) {
    // Capture the service before committing the local change. Invalidating the
    // stream afterward must not lose the pending country sync.
    final service = ref.read(pushServiceProvider);
    final scope = service.userSessionScope;
    await database.saveDetectedCountry(detected);
    current = await database.watchPreference().first;
    unawaited(_syncDetectedCountry(service, current, scope));
  }
  yield current;
  yield* database.watchPreference();
});

Future<void> _syncDetectedCountry(
  PushService service,
  CountryPreference preference,
  String scope,
) async {
  try {
    if (service.userSessionScope != scope) return;
    await service.markDetectedCountryDirty();
    if (service.authenticated && service.userSessionScope == scope) {
      await service.syncCountries(
        preference.detectedCountry,
        preference.selectedCountry,
        updateSelected: false,
      );
    }
  } catch (_) {
    // The startup route and cached screens must not wait for account I/O.
    // A failed remote sync keeps the dirty marker for the periodic retry.
  }
}

final temporaryInterestsProvider = StreamProvider<Set<String>>(
  (ref) => ref.watch(databaseProvider).watchTemporaryInterests(),
);

Future<void> recordTemporaryInterest(
  WidgetRef ref,
  String type,
  String id,
) async {
  if (!ref.context.mounted) return;
  await ref.read(databaseProvider).touchInterest(type, id);
  if (!ref.context.mounted) return;
  // Server interests belong to the account, not to push: a signed-in user
  // syncs them even in builds without push (touchInterest is a no-op for
  // guests).
  await ref.read(pushServiceProvider).touchInterest(type, id);
}

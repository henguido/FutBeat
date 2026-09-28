import 'dart:ui';

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

String countryName(String? code) =>
    const {
      'CR': 'Costa Rica',
      'MX': 'México',
      'AR': 'Argentina',
      'BR': 'Brasil',
      'ES': 'España',
      'US': 'Estados Unidos',
      'GB': 'Reino Unido',
    }[code] ??
    'Global';

final detectedCountryProvider = Provider<String?>(
  (_) => normalizeCountry(PlatformDispatcher.instance.locale.countryCode),
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
  final before = await database.watchPreference().first;
  final current = await refreshDetectedCountry(database, detected);
  if (before.detectedCountry != detected) {
    final service = ref.read(pushServiceProvider);
    await service.markDetectedCountryDirty();
    if (service.authenticated) {
      try {
        await service.syncCountries(
          current.detectedCountry,
          current.selectedCountry,
          updateSelected: false,
        );
      } catch (_) {
        // The dirty marker lets the periodic account loop retry offline.
      }
    }
  }
  yield current;
  yield* database.watchPreference();
});

final temporaryInterestsProvider = StreamProvider<Set<String>>(
  (ref) => ref.watch(databaseProvider).watchTemporaryInterests(),
);

Future<void> recordTemporaryInterest(
  WidgetRef ref,
  String type,
  String id,
) async {
  await ref.read(databaseProvider).touchInterest(type, id);
  if (PushService.configured) {
    await ref.read(pushServiceProvider).touchInterest(type, id);
  }
}

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

final preferenceProvider = StreamProvider<CountryPreference>((ref) async* {
  final database = ref.watch(databaseProvider);
  final detected = ref.watch(detectedCountryProvider);
  var current = await database.watchPreference().first;
  if (current.detectedCountry == null && detected != null) {
    await database.savePreference(
      detectedCountry: detected,
      selectedCountry: current.selectedCountry,
    );
  }
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

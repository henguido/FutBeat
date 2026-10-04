import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'entitlements.dart';

/// Where FutBeat may show an ad. Only non-intrusive slots: no Match
/// Center, no interstitials, no rewarded ads.
enum AdPlacement { matchesFeed }

/// Google's documented TEST banner unit (never a real FutBeat unit).
const admobTestBannerUnitId = 'ca-app-pub-3940256099942544/6300978111';

/// Ad units, only from build configuration:
/// `--dart-define=FUTBEAT_ADMOB_MATCHES_FEED_ID=<unit>` for a real unit, or
/// `--dart-define=FUTBEAT_ADMOB_TEST_ADS=true` for Google's test ads
/// (development / QA). Nothing configured = no ads at all.
class AdsConfig {
  const AdsConfig({this.matchesFeedUnitId = '', this.testAdsBuild = false});

  factory AdsConfig.fromEnvironment() {
    if (!Platform.isAndroid) return const AdsConfig();
    const testAds = bool.fromEnvironment('FUTBEAT_ADMOB_TEST_ADS');
    const feed = String.fromEnvironment('FUTBEAT_ADMOB_MATCHES_FEED_ID');
    return testAds
        ? const AdsConfig(
            matchesFeedUnitId: admobTestBannerUnitId,
            testAdsBuild: true,
          )
        : const AdsConfig(matchesFeedUnitId: feed);
  }

  final String matchesFeedUnitId;

  /// Built with `FUTBEAT_ADMOB_TEST_ADS=true`.
  final bool testAdsBuild;

  bool get configured => matchesFeedUnitId.isNotEmpty;

  /// Google test units only: QA may run them without production consent.
  bool get testAds =>
      testAdsBuild || matchesFeedUnitId == admobTestBannerUnitId;

  String? unitFor(AdPlacement placement) {
    final unit = switch (placement) {
      AdPlacement.matchesFeed => matchesFeedUnitId,
    };
    return unit.isEmpty ? null : unit;
  }
}

/// Answer of the consent platform (UMP / a Google-certified CMP).
class AdsConsentDecision {
  const AdsConsentDecision({
    required this.canRequestAds,
    required this.personalized,
  });

  /// Not known yet (no CMP, or its answer is still pending): no requests.
  static const unresolved = AdsConsentDecision(
    canRequestAds: false,
    personalized: false,
  );

  final bool canRequestAds;
  final bool personalized;
}

/// Production ad requests need [AdsConsentDecision.canRequestAds] from a
/// real consent platform. Non-personalized is NOT consent.
abstract interface class AdsConsent {
  Future<AdsConsentDecision> resolve();
}

/// Until UMP is integrated nothing authorizes production ads: fail closed.
class UnresolvedAdsConsent implements AdsConsent {
  const UnresolvedAdsConsent();

  @override
  Future<AdsConsentDecision> resolve() async => AdsConsentDecision.unresolved;
}

/// Google test ads for QA: allowed without production consent, never
/// personalized.
const _testAdsDecision = AdsConsentDecision(
  canRequestAds: true,
  personalized: false,
);

/// A loaded ad ready to be placed.
abstract interface class LoadedAd {
  Size get size;
  Widget widget();
  void dispose();
}

/// Loads ads; behind an interface so tests never reach AdMob.
abstract interface class AdLoader {
  /// null = nothing to show (no fill, error, timeout). Never throws.
  Future<LoadedAd?> loadBanner(String unitId, {required bool personalized});
}

/// The platform banner behind [GoogleAdLoader] (a seam for its tests).
abstract interface class PlatformBanner {
  Size get size;
  Future<void> load();
  Future<void> dispose();
  Widget widget();
}

typedef PlatformBannerFactory = PlatformBanner Function(
  String unitId, {
  required bool personalized,
  required void Function() onLoaded,
  required void Function() onFailed,
});

class _GoogleBanner implements PlatformBanner {
  _GoogleBanner(
    String unitId, {
    required bool personalized,
    required void Function() onLoaded,
    required void Function() onFailed,
  }) : ad = BannerAd(
         size: AdSize.banner,
         adUnitId: unitId,
         request: AdRequest(nonPersonalizedAds: !personalized),
         listener: BannerAdListener(
           onAdLoaded: (_) => onLoaded(),
           onAdFailedToLoad: (_, _) => onFailed(),
         ),
       );

  final BannerAd ad;

  @override
  Size get size => Size(ad.size.width.toDouble(), ad.size.height.toDouble());

  @override
  Future<void> load() => ad.load();

  @override
  Future<void> dispose() => ad.dispose();

  @override
  Widget widget() => AdWidget(ad: ad);
}

class GoogleAdLoader implements AdLoader {
  GoogleAdLoader({
    Future<void> Function()? initialize,
    PlatformBannerFactory? createBanner,
    this.timeout = const Duration(seconds: 30),
  }) : _initialize = initialize ?? _initializeSdk,
       _createBanner = createBanner ?? _GoogleBanner.new;

  static Future<void> _initializeSdk() => MobileAds.instance.initialize();

  final Future<void> Function() _initialize;
  final PlatformBannerFactory _createBanner;
  final Duration timeout;
  Future<void>? _initialized;

  @override
  Future<LoadedAd?> loadBanner(
    String unitId, {
    required bool personalized,
  }) async {
    try {
      // The SDK starts only when the first ad is really requested (never
      // for Premium users or without consent).
      await (_initialized ??= _initialize());
    } catch (_) {
      _initialized = null;
      return null;
    }
    final result = Completer<LoadedAd?>();
    Timer? timer;
    var finished = false;
    var released = false;
    late final PlatformBanner banner;

    // Every path ends here: the banner is disposed exactly once, and a
    // callback arriving after the timeout is ignored.
    void release() {
      if (released) return;
      released = true;
      unawaited(banner.dispose().catchError((Object _) {}));
    }

    void finish(LoadedAd? ad) {
      if (finished) return;
      finished = true;
      timer?.cancel();
      result.complete(ad);
    }

    banner = _createBanner(
      unitId,
      personalized: personalized,
      onLoaded: () {
        if (finished || released) {
          release();
          return;
        }
        finish(_LoadedBanner(banner, release));
      },
      onFailed: () {
        release();
        finish(null);
      },
    );
    timer = Timer(timeout, () {
      if (finished) return;
      release();
      finish(null);
    });
    try {
      await banner.load();
    } catch (_) {
      release();
      finish(null);
    }
    return result.future;
  }
}

class _LoadedBanner implements LoadedAd {
  _LoadedBanner(this.banner, this._release);

  final PlatformBanner banner;
  final void Function() _release;

  @override
  Size get size => banner.size;

  @override
  Widget widget() => banner.widget();

  @override
  void dispose() => _release();
}

final adsConfigProvider = Provider<AdsConfig>(
  (ref) => AdsConfig.fromEnvironment(),
);

final adLoaderProvider = Provider<AdLoader>((ref) => GoogleAdLoader());

/// Production consent; fails closed until a real CMP is wired here.
final adsConsentProvider = Provider<AdsConsent>(
  (ref) => const UnresolvedAdsConsent(),
);

/// The ONLY ads switch: configured ads, a settled plan for a resolved
/// account, and `showsAds` (FREE). Premium, an account still restoring or a
/// plan still loading never request an ad. Consent is checked per request.
final adsAllowedProvider = Provider<bool>((ref) {
  if (!ref.watch(adsConfigProvider).configured) return false;
  final plan = ref.watch(entitlementsProvider);
  return plan.accountResolved && plan.settled && plan.showsAds;
});

/// A discreet banner slot. Takes no space unless an ad really loaded, and
/// drops it the moment ads stop being allowed (upgrade, restore, account
/// change).
class AdSlot extends ConsumerStatefulWidget {
  const AdSlot(this.placement, {super.key});

  final AdPlacement placement;

  @override
  ConsumerState<AdSlot> createState() => _AdSlotState();
}

class _AdSlotState extends ConsumerState<AdSlot>
    with AutomaticKeepAliveClientMixin {
  LoadedAd? _ad;
  bool _requested = false;
  int _generation = 0;

  @override
  bool get wantKeepAlive => _ad != null;

  void _drop() {
    _generation++;
    _requested = false;
    _ad?.dispose();
    _ad = null;
  }

  Future<void> _load(String unitId) async {
    final generation = _generation;
    LoadedAd? ad;
    try {
      final consent = ref.read(adsConfigProvider).testAds
          ? _testAdsDecision
          : await ref.read(adsConsentProvider).resolve();
      if (consent.canRequestAds && mounted && generation == _generation) {
        ad = await ref
            .read(adLoaderProvider)
            .loadBanner(unitId, personalized: consent.personalized);
      }
    } catch (_) {
      ad = null;
    }
    if (!mounted ||
        generation != _generation ||
        !ref.read(adsAllowedProvider)) {
      ad?.dispose();
      return;
    }
    if (ad != null) {
      setState(() => _ad = ad);
      updateKeepAlive();
    }
  }

  @override
  void dispose() {
    _drop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final allowed = ref.watch(adsAllowedProvider);
    final unitId = ref.watch(adsConfigProvider).unitFor(widget.placement);
    if (!allowed || unitId == null) {
      if (_requested || _ad != null) _drop();
      return const SizedBox.shrink();
    }
    if (!_requested) {
      _requested = true;
      unawaited(_load(unitId));
    }
    final ad = _ad;
    if (ad == null) return const SizedBox.shrink();
    return Padding(
      key: ValueKey('ad-${widget.placement.name}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: SizedBox(
          width: ad.size.width,
          height: ad.size.height,
          child: ad.widget(),
        ),
      ),
    );
  }
}

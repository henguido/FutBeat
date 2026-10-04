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
  const AdsConfig({this.matchesFeedUnitId = ''});

  factory AdsConfig.fromEnvironment() {
    if (!Platform.isAndroid) return const AdsConfig();
    const testAds = bool.fromEnvironment('FUTBEAT_ADMOB_TEST_ADS');
    const feed = String.fromEnvironment('FUTBEAT_ADMOB_MATCHES_FEED_ID');
    return AdsConfig(matchesFeedUnitId: testAds ? admobTestBannerUnitId : feed);
  }

  final String matchesFeedUnitId;

  bool get configured => matchesFeedUnitId.isNotEmpty;

  String? unitFor(AdPlacement placement) {
    final unit = switch (placement) {
      AdPlacement.matchesFeed => matchesFeedUnitId,
    };
    return unit.isEmpty ? null : unit;
  }
}

/// What the user allowed. Production in the EEA / UK / Switzerland needs a
/// Google-certified CMP (UMP SDK) feeding this; until then FutBeat only
/// asks for NON-personalized ads and never shows a made-up consent form.
class AdsConsentDecision {
  const AdsConsentDecision({
    required this.canRequestAds,
    required this.personalized,
  });

  final bool canRequestAds;
  final bool personalized;
}

abstract interface class AdsConsent {
  Future<AdsConsentDecision> resolve();
}

/// Placeholder until UMP is integrated: non-personalized ads only.
class NonPersonalizedAdsConsent implements AdsConsent {
  const NonPersonalizedAdsConsent();

  @override
  Future<AdsConsentDecision> resolve() async =>
      const AdsConsentDecision(canRequestAds: true, personalized: false);
}

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

class GoogleAdLoader implements AdLoader {
  Future<void>? _initialized;

  @override
  Future<LoadedAd?> loadBanner(
    String unitId, {
    required bool personalized,
  }) async {
    try {
      // The SDK starts only when the first ad is really requested (never
      // for Premium users).
      await (_initialized ??= MobileAds.instance.initialize());
    } catch (_) {
      _initialized = null;
      return null;
    }
    final result = Completer<LoadedAd?>();
    final banner = BannerAd(
      size: AdSize.banner,
      adUnitId: unitId,
      request: AdRequest(nonPersonalizedAds: !personalized),
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          if (result.isCompleted) {
            ad.dispose();
          } else {
            result.complete(_Banner(ad as BannerAd));
          }
        },
        onAdFailedToLoad: (ad, _) {
          ad.dispose();
          if (!result.isCompleted) result.complete(null);
        },
      ),
    );
    try {
      await banner.load();
    } catch (_) {
      unawaited(banner.dispose());
      return null;
    }
    return result.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => null,
    );
  }
}

class _Banner implements LoadedAd {
  _Banner(this.ad);

  final BannerAd ad;

  @override
  Size get size => Size(ad.size.width.toDouble(), ad.size.height.toDouble());

  @override
  Widget widget() => AdWidget(ad: ad);

  @override
  void dispose() => unawaited(ad.dispose());
}

final adsConfigProvider = Provider<AdsConfig>(
  (ref) => AdsConfig.fromEnvironment(),
);

final adLoaderProvider = Provider<AdLoader>((ref) => GoogleAdLoader());

final adsConsentProvider = Provider<AdsConsent>(
  (ref) => const NonPersonalizedAdsConsent(),
);

/// The ONLY ads switch: configured ads, a settled plan for a resolved
/// account, and `showsAds` (FREE). Premium, an account still restoring or a
/// plan still loading never request an ad.
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
      final consent = await ref.read(adsConsentProvider).resolve();
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

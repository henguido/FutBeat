import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'entitlements.dart';
import 'theme.dart';

/// Where FutBeat may show an ad. Only non-intrusive slots: no Match
/// Center, no interstitials, no rewarded ads.
enum AdPlacement { matchesFeed }

/// Google's documented TEST banner unit (never a real FutBeat unit).
const admobTestBannerUnitId = 'ca-app-pub-3940256099942544/6300978111';

/// Google's publisher id for every documented test App ID / ad unit.
const admobTestPublisher = 'ca-app-pub-3940256099942544';

bool isGoogleTestAdId(String id) => id.startsWith(admobTestPublisher);

/// Ad units, only from build configuration:
/// `--dart-define=FUTBEAT_ADMOB_MATCHES_FEED_ID=<unit>` for a real unit, or
/// `--dart-define=FUTBEAT_ADMOB_TEST_ADS=true` for Google's test ads
/// (development / QA). Nothing configured = no ads at all.
class AdsConfig {
  const AdsConfig({this.matchesFeedUnitId = '', this.testAdsBuild = false});

  factory AdsConfig.fromEnvironment() {
    if (!Platform.isAndroid) return const AdsConfig();
    return AdsConfig.resolve(
      release: kReleaseMode,
      testAds: const bool.fromEnvironment('FUTBEAT_ADMOB_TEST_ADS'),
      matchesFeedUnitId: const String.fromEnvironment(
        'FUTBEAT_ADMOB_MATCHES_FEED_ID',
      ),
    );
  }

  /// Debug / profile: Google test ads when asked, or the configured unit.
  /// Release: production units only. A release binary never shows test ads
  /// (the Gradle release check refuses to build one; this is the runtime
  /// backstop): a test unit or the test flag there means no ads at all.
  factory AdsConfig.resolve({
    required bool release,
    required bool testAds,
    required String matchesFeedUnitId,
  }) {
    if (release) {
      return testAds || isGoogleTestAdId(matchesFeedUnitId)
          ? const AdsConfig()
          : AdsConfig(matchesFeedUnitId: matchesFeedUnitId);
    }
    return testAds
        ? const AdsConfig(
            matchesFeedUnitId: admobTestBannerUnitId,
            testAdsBuild: true,
          )
        : AdsConfig(matchesFeedUnitId: matchesFeedUnitId);
  }

  final String matchesFeedUnitId;

  /// Built with `FUTBEAT_ADMOB_TEST_ADS=true`.
  final bool testAdsBuild;

  bool get configured => matchesFeedUnitId.isNotEmpty;

  /// Google test units only: QA may run them without production consent
  /// (UMP is not involved).
  bool get testAds => testAdsBuild || isGoogleTestAdId(matchesFeedUnitId);

  String? unitFor(AdPlacement placement) {
    final unit = switch (placement) {
      AdPlacement.matchesFeed => matchesFeedUnitId,
    };
    return unit.isEmpty ? null : unit;
  }
}

/// Consent for production ads, as Google's User Messaging Platform (UMP)
/// reports it. Only [canRequestAds] lets a production ad be requested.
enum AdsConsentState {
  /// Not known yet, still being gathered, or UMP failed: no ads.
  unresolved,
  canRequestAds,
  cannotRequestAds,
}

/// Google UMP (bundled with google_mobile_ads): Google's own consent
/// messages and forms, configured in AdMob "Privacy & messaging". FutBeat
/// shows no consent text of its own.
abstract interface class UmpPlatform {
  /// Refreshes consent info; throws on failure.
  Future<void> requestConsentInfoUpdate();

  /// Shows Google's form only when UMP says it is required; throws on a
  /// form error.
  Future<void> showConsentFormIfRequired();
  Future<bool> canRequestAds();
  Future<bool> privacyOptionsRequired();

  /// Google's privacy options form (for a future "Privacidad" action).
  Future<void> showPrivacyOptionsForm();
}

class GoogleUmpPlatform implements UmpPlatform {
  ConsentInformation get _info => ConsentInformation.instance;

  @override
  Future<void> requestConsentInfoUpdate() {
    final done = Completer<void>();
    _info.requestConsentInfoUpdate(
      ConsentRequestParameters(),
      () => done.complete(),
      (error) => done.completeError(StateError(error.message)),
    );
    return done.future;
  }

  @override
  Future<void> showConsentFormIfRequired() {
    final done = Completer<void>();
    ConsentForm.loadAndShowConsentFormIfRequired((error) {
      if (error == null) {
        done.complete();
      } else {
        done.completeError(StateError(error.message));
      }
    });
    return done.future;
  }

  @override
  Future<bool> canRequestAds() => _info.canRequestAds();

  @override
  Future<bool> privacyOptionsRequired() async =>
      await _info.getPrivacyOptionsRequirementStatus() ==
      PrivacyOptionsRequirementStatus.required;

  @override
  Future<void> showPrivacyOptionsForm() {
    final done = Completer<void>();
    ConsentForm.showPrivacyOptionsForm((error) {
      if (error == null) {
        done.complete();
      } else {
        done.completeError(StateError(error.message));
      }
    });
    return done.future;
  }
}

/// UMP on Android; nowhere else (no consent = no production ads).
final umpPlatformProvider = Provider<UmpPlatform?>(
  (ref) => Platform.isAndroid ? GoogleUmpPlatform() : null,
);

final adsConsentProvider =
    NotifierProvider<AdsConsentController, AdsConsentState>(
      AdsConsentController.new,
    );

/// Gathers consent once per app session, only for someone who would see
/// ads (never for Premium). Any failure keeps [AdsConsentState.unresolved].
/// Upper bound for UMP's consent info update (network).
const umpUpdateTimeout = Duration(seconds: 15);

class AdsConsentController extends Notifier<AdsConsentState> {
  Future<void>? _gathering;

  @override
  AdsConsentState build() => AdsConsentState.unresolved;

  /// Idempotent: the first call runs UMP (update, then Google's form only if
  /// required); later calls reuse it, so no form is shown repeatedly.
  Future<void> ensure() => _gathering ??= _gather();

  Future<void> _gather() async {
    final ump = ref.read(umpPlatformProvider);
    if (ump == null) return;
    try {
      // Network step bounded (offline must not leave it pending forever);
      // the form itself waits for the user.
      await ump.requestConsentInfoUpdate().timeout(umpUpdateTimeout);
      await ump.showConsentFormIfRequired();
      final allowed = await ump.canRequestAds();
      if (!ref.mounted) return;
      state = allowed
          ? AdsConsentState.canRequestAds
          : AdsConsentState.cannotRequestAds;
    } catch (_) {
      // Fail closed for this session; retried on the next app start.
    }
  }

  /// Whether Google requires a privacy options entry point for this user.
  Future<bool> privacyOptionsRequired() async {
    final ump = ref.read(umpPlatformProvider);
    if (ump == null) return false;
    try {
      return await ump.privacyOptionsRequired();
    } catch (_) {
      return false;
    }
  }

  /// Opens Google's privacy options form and re-reads the decision.
  Future<void> showPrivacyOptions() async {
    final ump = ref.read(umpPlatformProvider);
    if (ump == null) return;
    try {
      await ump.showPrivacyOptionsForm();
      final allowed = await ump.canRequestAds();
      if (!ref.mounted) return;
      state = allowed
          ? AdsConsentState.canRequestAds
          : AdsConsentState.cannotRequestAds;
    } catch (_) {
      if (ref.mounted) state = AdsConsentState.unresolved;
    }
  }
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

/// In-feed banner sized to the screen width (Google's anchored adaptive
/// size, height known before loading: no layout jump), falling back to the
/// standard 320x50 banner.
class _GoogleBanner implements PlatformBanner {
  _GoogleBanner(
    this.unitId, {
    required this.personalized,
    required this.onLoaded,
    required this.onFailed,
  });

  final String unitId;
  final bool personalized;
  final void Function() onLoaded;
  final void Function() onFailed;
  BannerAd? _ad;
  bool _disposed = false;

  /// Feed side margins the banner stays within.
  static const _feedMargin = 32;

  /// Standard banner, when no adaptive size is available.
  static const _standard = AdSize(width: 320, height: 50);

  @override
  Size get size {
    final value = _ad?.size ?? _standard;
    return Size(value.width.toDouble(), value.height.toDouble());
  }

  @override
  Future<void> load() async {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final width = (view.physicalSize.width / view.devicePixelRatio).truncate();
    AdSize size = _standard;
    try {
      size =
          await AdSize.getLargeAnchoredAdaptiveBannerAdSize(
            width - _feedMargin,
          ) ??
          _standard;
    } catch (_) {}
    if (_disposed) return;
    final ad = BannerAd(
      size: size,
      adUnitId: unitId,
      request: AdRequest(nonPersonalizedAds: !personalized),
      listener: BannerAdListener(
        onAdLoaded: (_) => onLoaded(),
        onAdFailedToLoad: (_, _) => onFailed(),
      ),
    );
    _ad = ad;
    await ad.load();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _ad?.dispose();
  }

  @override
  Widget widget() => AdWidget(ad: _ad!);
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
/// Google requires a privacy options entry point for this user. Re-read
/// whenever the consent decision changes; unknown or any error = hidden.
final adsPrivacyOptionsRequiredProvider = FutureProvider<bool>((ref) {
  // Only someone who would get production ads: Premium, unconfigured and
  // test-ads builds never query UMP.
  if (!ref.watch(adsEligibleProvider) || ref.watch(adsConfigProvider).testAds) {
    return false;
  }
  ref.watch(adsConsentProvider);
  return ref.read(adsConsentProvider.notifier).privacyOptionsRequired();
});

/// The plan wants ads: configured units, a settled plan for a resolved
/// account, and `showsAds` (FREE). Premium is never eligible, so it never
/// sees a consent form, initializes the SDK or requests an ad.
final adsEligibleProvider = Provider<bool>((ref) {
  if (!ref.watch(adsConfigProvider).configured) return false;
  final plan = ref.watch(entitlementsProvider);
  return plan.accountResolved && plan.settled && plan.showsAds;
});

/// The ONLY ads switch: eligible, and for production units UMP said
/// [AdsConsentState.canRequestAds]. Google test ads (QA) need no
/// production consent.
final adsAllowedProvider = Provider<bool>((ref) {
  if (!ref.watch(adsEligibleProvider)) return false;
  if (ref.watch(adsConfigProvider).testAds) return true;
  return ref.watch(adsConsentProvider) == AdsConsentState.canRequestAds;
});

/// Starts UMP as soon as someone is eligible for ads (app start), so
/// Google's form, when required, never appears mid-scroll.
void ensureAdsConsent(WidgetRef ref) {
  if (ref.read(adsEligibleProvider) && !ref.read(adsConfigProvider).testAds) {
    unawaited(ref.read(adsConsentProvider.notifier).ensure());
  }
}

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
      // Production: personalization follows the UMP (TCF) decision; test
      // ads are never personalized.
      ad = await ref
          .read(adLoaderProvider)
          .loadBanner(
            unitId,
            personalized: !ref.read(adsConfigProvider).testAds,
          );
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
    if (ref.watch(adsEligibleProvider)) ensureAdsConsent(ref);
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
    // A feed block like the match cards: card colour and radius behind
    // the adaptive banner (no dark band around it), a small gap from the
    // cards. Only built once an ad loaded, so nothing is reserved before.
    return Padding(
      key: ValueKey('ad-${widget.placement.name}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: panel,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Center(
            child: SizedBox(
              width: ad.size.width,
              height: ad.size.height,
              child: ad.widget(),
            ),
          ),
        ),
      ),
    );
  }
}

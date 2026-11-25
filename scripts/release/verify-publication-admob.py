"""Read-only final AdMob gate. Inspect a bundletool manifest and its build inputs.

This is a publication gate, not a replacement for signature/bundle validation.
It never initializes AdMob, uploads a bundle, or changes any service.
"""
import argparse
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

ANDROID = '{http://schemas.android.com/apk/res/android}'
TEST_PUBLISHER = 'ca-app-pub-3940256099942544'


def problems(manifest, config, expected_app, expected_feed):
    errors = []
    root = ET.fromstring(manifest)
    app = root.find('application')
    if root.get('package') != 'com.futbeat.futbeat' or app is None:
        return ['Not the official FutBeat application manifest']
    if app.get(ANDROID + 'debuggable') == 'true':
        errors.append('Debuggable artifact')
    ids = [m.get(ANDROID + 'value', '') for m in app.findall('meta-data')
           if m.get(ANDROID + 'name') == 'com.google.android.gms.ads.APPLICATION_ID']
    if len(ids) != 1 or ids[0] != expected_app:
        errors.append('Manifest AdMob App ID differs from the reviewed value')
    if not re.fullmatch(r'ca-app-pub-\d{16}~\d{10}', expected_app):
        errors.append('Invalid expected App ID')
    if not re.fullmatch(r'ca-app-pub-\d{16}/\d{10}', expected_feed):
        errors.append('Invalid expected banner ID')
    if expected_app.startswith(TEST_PUBLISHER) or expected_feed.startswith(TEST_PUBLISHER):
        errors.append('Google sample identifiers cannot be published')
    if expected_app.split('~')[0] != expected_feed.split('/')[0]:
        errors.append('App and banner belong to different publishers')
    if config.get('FUTBEAT_ADMOB_MATCHES_FEED_ID') != expected_feed:
        errors.append('Matches banner differs from the reviewed value')
    for flag in ('FUTBEAT_ADS_DISABLED', 'FUTBEAT_ADMOB_TEST_ADS'):
        if config.get(flag) is not False:
            errors.append(flag + ' must explicitly be false for Free with production ads')
    for flag in ('FUTBEAT_USE_DEMO', 'FUTBEAT_QA_LOCAL_CACHE_ONLY',
                 'FUTBEAT_QA_DIAGNOSTICS', 'FUTBEAT_QA_ISOLATED_PACKAGE',
                 'FUTBEAT_PREMIUM_PLAY_QA', 'FUTBEAT_INTEGRAL_QA',
                 'FUTBEAT_COMMERCIAL_UMP'):
        if config.get(flag) not in (None, False):
            errors.append(flag + ' is not a publication setting')
    production = 'https://izlmruqawgagwdcsjhte.supabase.co'
    server_enabled = config.get('FUTBEAT_PREMIUM_SERVER_ENABLED') is True
    if server_enabled:
        if (config.get('BILLING_BASE') != production + '/functions/v1/futbeat-billing'
                or config.get('FUTBEAT_SUPABASE_URL', '').rstrip('/') != production
                or config.get('FUTBEAT_USER_SESSION_ACCESS') is not True):
            errors.append('Premium requires paired production Auth/Billing and user-session access')
    elif config.get('BILLING_BASE'):
        errors.append('Billing requires explicit production server verification')
    return errors


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--manifest', type=Path, required=True)
    p.add_argument('--config', type=Path, required=True)
    p.add_argument('--expected-app-id', required=True)
    p.add_argument('--expected-feed-id', required=True)
    args = p.parse_args()
    try:
        errors = problems(args.manifest.read_text(encoding='utf-8-sig'),
                          json.loads(args.config.read_text(encoding='utf-8-sig')),
                          args.expected_app_id, args.expected_feed_id)
    except (OSError, ValueError, ET.ParseError):
        errors = ['Unreadable or malformed manifest/configuration']
    print(json.dumps({'status': 'NO-GO' if errors else 'PASS_ADMOB_ONLY',
                      'errors': errors}, indent=2))
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())

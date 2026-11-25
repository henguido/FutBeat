"""Offline regressions for the final publication gate; never request real ads."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    'publication_admob', Path(__file__).with_name('verify-publication-admob.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class PublicationAdsTest(unittest.TestCase):
    def setUp(self):
        self.app = 'ca-app-pub-1234567890123456~1234567890'
        self.feed = 'ca-app-pub-1234567890123456/1234567890'
        self.config = {'FUTBEAT_ADS_DISABLED': False,
                       'FUTBEAT_ADMOB_TEST_ADS': False,
                       'FUTBEAT_ADMOB_MATCHES_FEED_ID': self.feed}
        self.xml = ('<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
                    'package="com.futbeat.futbeat"><application><meta-data '
                    'android:name="com.google.android.gms.ads.APPLICATION_ID" '
                    f'android:value="{self.app}"/></application></manifest>')

    def check(self, xml=None, config=None, app=None, feed=None):
        return gate.problems(self.xml if xml is None else xml,
                             self.config if config is None else config,
                             self.app if app is None else app,
                             self.feed if feed is None else feed)

    def test_reviewed_config(self):
        self.assertEqual(self.check(), [])

    def test_sample_manifest_is_blocked_even_with_real_config(self):
        self.assertTrue(self.check(xml=self.xml.replace(
            self.app, 'ca-app-pub-3940256099942544~3347511713')))

    def test_reviewing_sample_ids_does_not_allow_them(self):
        self.assertTrue(self.check(app='ca-app-pub-3940256099942544~3347511713'))

    def test_wrong_banner_from_same_publisher(self):
        self.config['FUTBEAT_ADMOB_MATCHES_FEED_ID'] = self.feed[:-1] + '1'
        self.assertTrue(self.check())

    def test_cross_publisher_banner(self):
        self.assertTrue(self.check(feed='ca-app-pub-6543210987654321/1234567890'))

    def test_disabled_ads_cannot_qualify_free_with_ads(self):
        self.config['FUTBEAT_ADS_DISABLED'] = True
        self.assertTrue(self.check())

    def test_test_ads_are_blocked(self):
        self.config['FUTBEAT_ADMOB_TEST_ADS'] = True
        self.assertTrue(self.check())

    def test_qa_modes_are_blocked(self):
        for flag in ('FUTBEAT_QA_ISOLATED_PACKAGE', 'FUTBEAT_COMMERCIAL_UMP',
                     'FUTBEAT_PREMIUM_PLAY_QA', 'FUTBEAT_QA_DIAGNOSTICS'):
            with self.subTest(flag=flag):
                self.assertTrue(self.check(config={**self.config, flag: True}))

    def test_qa_billing_is_blocked(self):
        self.config['BILLING_BASE'] = 'https://fixture.invalid'
        self.assertTrue(self.check())

    def test_production_billing_requires_paired_project_and_explicit_opt_in(self):
        auth = 'https://izlmruqawgagwdcsjhte.supabase.co'
        self.config.update(FUTBEAT_PREMIUM_SERVER_ENABLED=True,
                           FUTBEAT_USER_SESSION_ACCESS=True,
                           FUTBEAT_SUPABASE_URL=auth,
                           BILLING_BASE=auth + '/functions/v1/futbeat-billing')
        self.assertEqual(self.check(), [])
        self.config['BILLING_BASE'] = 'https://fixture.invalid'
        self.assertTrue(self.check())

    def test_incomplete_production_billing_cannot_pass(self):
        self.config['FUTBEAT_PREMIUM_SERVER_ENABLED'] = True
        self.assertTrue(self.check())

    def test_debug_and_different_package_are_blocked(self):
        self.assertTrue(self.check(xml=self.xml.replace(
            '<application>', '<application android:debuggable="true">')))
        self.assertTrue(self.check(xml=self.xml.replace('com.futbeat.futbeat"',
                                                      'com.futbeat.futbeat.qa"')))


if __name__ == '__main__':
    unittest.main()

import argparse
from datetime import datetime, timezone
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'testflight.py'
spec = importlib.util.spec_from_file_location('testflight', SCRIPT)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class TestFlightSmokeTests(unittest.TestCase):
    def options(self, directory, archive_only=False):
        return argparse.Namespace(team='TESTTEAM01', build_number='2460.10.25',
                                  work_dir=Path(directory), archive_only=archive_only, dry_run=False)

    def test_failed_checks_prevent_archive_and_upload(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(release, 'clean_revision', return_value='fixture-commit'), \
             patch.object(release.subprocess, 'run', side_effect=[subprocess.CompletedProcess([], 0),
                         subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 1)]) as run:
            with self.assertRaisesRegex(RuntimeError, 'Core tests failed'):
                release.execute(self.options(directory), {})
            self.assertEqual(run.call_count, 3)
            self.assertFalse(any('xcodebuild' in call.args[0] for call in run.call_args_list))

    def test_internal_upload_and_archive_only_mode(self):
        for archive_only in (False, True):
            with self.subTest(archive_only=archive_only), tempfile.TemporaryDirectory() as directory, \
                 patch.object(release, 'clean_revision', return_value='fixture-commit'), \
                 patch.object(release.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run:
                release.execute(self.options(directory, archive_only), {})
                commands = [call.args[0] for call in run.call_args_list]
                self.assertEqual(any('-exportArchive' in command for command in commands), not archive_only)
                options = plistlib.loads((Path(directory) / 'ExportOptions.plist').read_bytes())
                self.assertTrue(options['testFlightInternalTestingOnly'])
                self.assertEqual(options['destination'], 'upload')
                self.assertTrue(options['uploadSymbols'])
                self.assertTrue((Path(directory) / 'timings.json').exists())

    def test_changed_source_prevents_upload(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(release, 'clean_revision', side_effect=['before', 'after']), \
             patch.object(release.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run:
            with self.assertRaisesRegex(ValueError, 'source changed'):
                release.execute(self.options(directory), {})
            self.assertFalse(any('-exportArchive' in call.args[0] for call in run.call_args_list))

    def test_partial_credentials_fail_before_build(self):
        with self.assertRaisesRegex(ValueError, 'together'):
            release.authentication({'ASC_KEY_ID': 'fixture'})

    def test_distribution_profile_uses_manual_signing_for_archive_and_export(self):
        profile = '12345678-ABCD-1234-ABCD-123456789ABC'
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(release, 'clean_revision', return_value='fixture'), \
             patch.object(release.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run:
            release.execute(self.options(directory), {'PLACES_PROFILE_UUID': profile})
            archive = next(call.args[0] for call in run.call_args_list if 'archive' in call.args[0])
            self.assertIn('CODE_SIGN_IDENTITY=Apple Distribution', archive)
            self.assertIn('PROVISIONING_PROFILE_SPECIFIER=' + profile, archive)
            options = plistlib.loads((Path(directory) / 'ExportOptions.plist').read_bytes())
            self.assertEqual(options['signingStyle'], 'manual')
            self.assertEqual(options['provisioningProfiles'], {'com.adriaan.places': profile})

    def test_generated_build_numbers_are_ordered_and_valid(self):
        before = release.build_number(datetime(2026, 9, 25, 10, 59, tzinfo=timezone.utc))
        after = release.build_number(datetime(2026, 9, 25, 11, 0, tzinfo=timezone.utc))
        self.assertLess(tuple(map(int, before.split('.'))), tuple(map(int, after.split('.'))))
        self.assertRegex(after, r'^\d{1,4}\.\d{1,2}\.\d{1,2}$')

    def test_profile_authentication_signature_and_expiry(self):
        # A synthetic key checks the real OpenSSL ES256 encoding, offline.
        ruby = '''
          require ARGV.shift
          key = OpenSSL::PKey::EC.generate('prime256v1')
          File.write(ARGV[0], key.to_pem)
          token = PlacesTestFlightProfile.token(ARGV[0], 'fixture', 'fixture-issuer', now: 1000)
          header, payload, encoded_signature = token.split('.')
          claims = JSON.parse(Base64.urlsafe_decode64(payload))
          raise 'Invalid expiry' unless claims['iat'] == 1000 && claims['exp'] == 1300
          raise 'Invalid audience' unless claims['aud'] == 'appstoreconnect-v1'
          signature = Base64.urlsafe_decode64(encoded_signature)
          raise 'Invalid signature size' unless signature.bytesize == 64
          integers = [signature[0,32], signature[32,32]].map do |part|
            OpenSSL::ASN1::Integer.new(OpenSSL::BN.new(part, 2))
          end
          der = OpenSSL::ASN1::Sequence.new(integers).to_der
          raise 'Invalid signature' unless key.verify('SHA256', der, header + '.' + payload)
        '''
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(['ruby', '-e', ruby,
                                     str(SCRIPT.with_name('download_testflight_profile.rb')),
                                     str(Path(directory) / 'fixture.pem')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_workflow_only_releases_main_and_keeps_full_ci_separate(self):
        root = SCRIPT.parents[1]
        workflow = (root / '.github/workflows/testflight.yml').read_text()
        self.assertIn("github.ref == 'refs/heads/main'", workflow)
        self.assertIn("vars.PLACES_TESTFLIGHT_ENABLED == 'true'", workflow)
        self.assertNotIn('pull_request:', workflow)
        self.assertNotIn('pull_request_target:', workflow)
        self.assertIn('run: python3 scripts/testflight.py', workflow)
        self.assertIn('if: always()', workflow)
        self.assertIn('Permission-free UI smoke tests', (root / '.github/workflows/ci.yml').read_text())


if __name__ == '__main__':
    unittest.main()

import argparse
from datetime import datetime, timezone
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'testflight.py'
spec = importlib.util.spec_from_file_location('testflight', SCRIPT)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class TestFlightSmokeTests(unittest.TestCase):
    def test_support_symbols_are_retained_without_signing_material(self):
        workflow = (SCRIPT.parents[1] / '.github/workflows/testflight.yml').read_text()
        step = workflow.split('      - name: Keep symbols for user-exported crash reports', 1)[1].split('      - name:', 1)[0]
        self.assertIn('if: always()', step)
        self.assertIn('path: build/testflight/Places.xcarchive/dSYMs/', step)
        self.assertIn('retention-days: 90', step)
        self.assertIn('github.sha', step)
        self.assertEqual(sum(line.strip().startswith('path:') for line in step.splitlines()), 1)
        self.assertNotIn('include-hidden-files: true', step)
        self.assertNotIn('RUNNER_TEMP', step)

    def test_distribution_profile_checks_companion_capabilities(self):
        profile = {'TeamIdentifier': ['TEAM'], 'UUID': '12345678-ABCD-1234-ABCD-123456789ABC',
                   'ExpirationDate': datetime(2030, 1, 1), 'Entitlements': {
                       'application-identifier': 'TEAM.com.adriaan.places', 'beta-reports-active': True,
                       'com.apple.developer.icloud-container-identifiers': ['iCloud.com.adriaan.places'],
                       'aps-environment': 'production'}}
        now = datetime(2026, 1, 1, tzinfo=timezone.utc)
        self.assertEqual(release.validate_distribution_profile(profile, 'TEAM', 'com.adriaan.places', now), profile['UUID'])
        del profile['Entitlements']['aps-environment']
        with self.assertRaisesRegex(ValueError, 'Push Notifications'):
            release.validate_distribution_profile(profile, 'TEAM', 'com.adriaan.places', now)
        with self.assertRaisesRegex(ValueError, 'different team or app'):
            release.validate_distribution_profile(profile, 'OTHER', 'com.adriaan.places.watch', now)

    def test_cache_report_uses_xcode_totals_without_double_counting(self):
        log = ('note: Replay cache hit\nCache hit\n'
               'CompilationCacheMetrics\nnote: 285 hits / 290 cacheable tasks (98%)\n')
        self.assertEqual(release.compilation_cache_summary(log), {'hits': 285, 'misses': 5})
        self.assertIsNone(release.compilation_cache_summary('No metrics were emitted.'))

    def options(self, directory, archive_only=False):
        return argparse.Namespace(team='TESTTEAM01', build_number='2460.10.25',
                                  work_dir=Path(directory), archive_only=archive_only, dry_run=False,
                                  skip_tests=False)

    def test_ci_skips_tests_but_still_checks_archives_and_uploads(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(release, 'clean_revision', return_value='fixture-commit'), \
             patch.object(release.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run:
            options = self.options(directory)
            options.skip_tests = True
            release.execute(options, {})
            commands = [call.args[0] for call in run.call_args_list]
            self.assertEqual(len(commands), 3)
            self.assertIn('scripts/check_privacy.py', commands[0])
            archive = commands[1]
            self.assertIn('archive', archive)
            self.assertIn('COMPILATION_CACHE_ENABLE_CACHING=YES', archive)
            self.assertIn(f'COMPILATION_CACHE_CAS_PATH={Path(directory).resolve() / "CompilationCache.noindex"}', archive)
            self.assertIn('-exportArchive', commands[2])

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
                self.assertEqual(options['iCloudContainerEnvironment'], 'Production')
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

    def test_missing_watch_distribution_profiles_fail_before_build(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(release.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'Manual signing also requires'):
                release.execute(self.options(directory), {'PLACES_PROFILE_UUID': '12345678-ABCD-1234-ABCD-123456789ABC'})
            run.assert_not_called()

    def test_distribution_profile_uses_manual_signing_for_archive_and_export(self):
        profile = '12345678-ABCD-1234-ABCD-123456789ABC'
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(release, 'clean_revision', return_value='fixture'), \
             patch.object(release.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run:
            release.execute(self.options(directory), {'PLACES_PROFILE_UUID': profile,
                'PLACES_WATCH_PROFILE_UUID': profile, 'PLACES_COMPLICATION_PROFILE_UUID': profile})
            archive = next(call.args[0] for call in run.call_args_list if 'archive' in call.args[0])
            self.assertIn('PLACES_CODE_SIGN_IDENTITY=Apple Distribution', archive)
            self.assertIn('PLACES_CODE_SIGN_STYLE=Manual', archive)
            self.assertIn('PLACES_PROFILE_UUID=' + profile, archive)
            for setting in ('CODE_SIGN_IDENTITY=', 'CODE_SIGN_STYLE=', 'PROVISIONING_PROFILE_SPECIFIER='):
                self.assertFalse(any(argument.startswith(setting) for argument in archive))
            options = plistlib.loads((Path(directory) / 'ExportOptions.plist').read_bytes())
            self.assertEqual(options['signingStyle'], 'manual')
        self.assertEqual(options['provisioningProfiles'], {bundle: profile for bundle in
                ['com.adriaan.places', 'com.adriaan.places.watch', 'com.adriaan.places.watch.widgets']})

    def test_mac_archive_and_export_are_separate_from_iphone_and_watch(self):
        profile = '12345678-ABCD-1234-ABCD-123456789ABC'
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(release, 'clean_revision', return_value='fixture'), \
             patch.object(release.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run:
            args = self.options(directory)
            args.platform = 'macos'
            args.skip_tests = True
            release.execute(args, {'PLACES_MAC_PROFILE_UUID': profile})
            archive = next(call.args[0] for call in run.call_args_list if 'archive' in call.args[0])
            self.assertIn('PlacesMac', archive)
            self.assertIn('generic/platform=macOS', archive)
            self.assertIn('PLACES_MAC_PROFILE_UUID=' + profile, archive)
            self.assertFalse(any('PLACES_WATCH_PROFILE_UUID' in value for value in archive))
            self.assertIn(str(Path(directory).resolve() / 'PlacesMac.xcarchive'), archive)
            options = plistlib.loads((Path(directory) / 'ExportOptions.plist').read_bytes())
            self.assertEqual(options['provisioningProfiles'], {'com.adriaan.places': profile})
            self.assertEqual(options['installerSigningCertificate'], 'Mac Installer Distribution')
            self.assertTrue(options['testFlightInternalTestingOnly'])

    def test_mac_profile_rejects_wrong_platform_development_and_direct_distribution(self):
        profile = {'TeamIdentifier': ['TEAM'], 'UUID': '12345678-ABCD-1234-ABCD-123456789ABC',
                   'Platform': ['OSX'], 'ExpirationDate': datetime(2030, 1, 1), 'Entitlements': {
                       'com.apple.application-identifier': 'TEAM.com.adriaan.places',
                       'com.apple.developer.icloud-container-identifiers': ['iCloud.com.adriaan.places'],
                       'com.apple.developer.icloud-container-environment': ['Production']}}
        def validate(value):
            return release.validate_distribution_profile(value, 'TEAM', 'com.adriaan.places',
                datetime(2026, 1, 1, tzinfo=timezone.utc), platform='macos')
        self.assertEqual(validate(profile), profile['UUID'])
        for change in ({'Platform': ['iOS']}, {'ProvisionedDevices': ['fixture']}, {'ProvisionsAllDevices': True}):
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, 'App Store'):
                validate({**profile, **change})
        for key, value in [('com.apple.security.get-task-allow', True),
                           ('com.apple.developer.icloud-container-environment', ['Development'])]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate({**profile, 'Entitlements': {**profile['Entitlements'], key: value}})

    def test_mac_workflow_uses_isolated_caches_signing_and_symbols(self):
        workflow = (SCRIPT.parents[1] / '.github/workflows/testflight-mac.yml').read_text()
        self.assertIn("github.ref == 'refs/heads/main'", workflow)
        self.assertIn("vars.PLACES_MAC_TESTFLIGHT_ENABLED == 'true'", workflow)
        self.assertIn("- 'apps/macos/**'", workflow)
        self.assertIn('python3 scripts/testflight.py --platform macos --skip-tests', workflow)
        self.assertIn('build/testflight-macos/SourcePackages', workflow)
        self.assertIn('build/testflight-macos/CompilationCache.noindex', workflow)
        self.assertIn('build/testflight-macos/PlacesMac.xcarchive/dSYMs/', workflow)
        self.assertIn("'PLACES_PROFILE_TYPE': 'MAC_APP_STORE'", workflow)
        self.assertIn("platform='macos'", workflow)
        self.assertIn('secrets.PLACES_MAC_INSTALLER_P12', workflow)
        self.assertNotIn('pull_request:', workflow)
        self.assertNotIn('swift test', workflow)
        self.assertNotIn('unittest discover', workflow)

    @unittest.skipUnless(sys.platform == 'darwin', 'Xcode project validation uses macOS plutil')
    def test_profile_settings_are_scoped_to_the_app_release_target(self):
        project = SCRIPT.parents[1] / 'apps/ios/Places.xcodeproj/project.pbxproj'
        # Read the generated project to catch misplaced project-wide settings.
        settings = plistlib.loads(subprocess.check_output(['plutil', '-convert', 'xml1', '-o', '-', str(project)]))
        objects = settings['objects']
        configured = []
        expected = {'Places': 'PLACES_PROFILE_UUID', 'PlacesWatch': 'PLACES_WATCH_PROFILE_UUID',
                    'PlacesComplication': 'PLACES_COMPLICATION_PROFILE_UUID', 'PlacesMac': 'PLACES_MAC_PROFILE_UUID'}
        for target in objects.values():
            if target.get('isa') not in ('PBXNativeTarget', 'PBXProject'):
                continue
            for config_id in objects[target['buildConfigurationList']]['buildConfigurations']:
                config = objects[config_id]
                values = config['buildSettings']
                if 'PROVISIONING_PROFILE_SPECIFIER' in values:
                    configured.append((target.get('name'), config['name']))
                    self.assertEqual(values['PROVISIONING_PROFILE_SPECIFIER'], '$(' + expected[target['name']] + ')')
                    self.assertEqual(values['CODE_SIGN_STYLE'], '$(PLACES_CODE_SIGN_STYLE)')
                    self.assertEqual(values['PLACES_CODE_SIGN_STYLE'], 'Automatic')
        self.assertEqual(sorted(configured), sorted((target, 'Release') for target in expected))

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

    def test_workflow_only_releases_main_and_runs_tests_locally(self):
        root = SCRIPT.parents[1]
        workflow = (root / '.github/workflows/testflight.yml').read_text()
        self.assertIn("'packages/PlacesRouting/**'", workflow)
        self.assertIn("github.ref == 'refs/heads/main'", workflow)
        self.assertIn("vars.PLACES_TESTFLIGHT_ENABLED == 'true'", workflow)
        self.assertNotIn('pull_request:', workflow)
        self.assertNotIn('pull_request_target:', workflow)
        self.assertIn('run: python3 scripts/testflight.py --skip-tests', workflow)
        self.assertIn('if: always()', workflow)
        validation = (root / '.github/workflows/ci.yml').read_text()
        for text in (workflow, validation):
            self.assertNotIn('swift test', text)
            self.assertNotIn('unittest discover', text)
            self.assertNotIn('bootstatus', text)
            self.assertIn('/CompilationCache.noindex', text)
            self.assertIn('/SourcePackages', text)
            self.assertNotIn('packages/PlacesCore/.build', text)
        local = (root / 'scripts/validate_local.py').read_text()
        self.assertIn("'swift', 'test'", local)
        self.assertIn("'unittest', 'discover'", local)
        self.assertIn("'test'", local)


if __name__ == '__main__':
    unittest.main()

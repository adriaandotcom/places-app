from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_privacy import ResourceParser, check_css, check_resource, check_map_manifest, has_remote_url, check_companion_cloud
import json
from copy import deepcopy


class PrivacySmokeTests(unittest.TestCase):
    def test_cloud_inbox_rejects_plain_fields_public_database_and_missing_consent(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / 'packages/PlacesCompanion/Sources/PlacesCompanion/CloudInbox.swift').read_text()
        self.assertEqual(check_companion_cloud(source), [])
        for changed in [source.replace('guard consented else', 'if false'),
                        source.replace('privateCloudDatabase', 'publicCloudDatabase'),
                        source + '\nrecord["latitude"] = sample.latitude',
                        source.replace('CompanionCipher.seal(', 'JSONEncoder().encode(')]:
            self.assertTrue(check_companion_cloud(changed))

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / 'local.woff2').write_bytes(b'fixture')

    def tearDown(self):
        self.temp.cleanup()

    def test_local_font_allowed(self):
        self.assertEqual(check_css('src:url("local.woff2")', self.root, self.root), [])

    def test_gpx_namespace_is_not_a_remote_request(self):
        namespace = 'xmlns="http://www.topografix.com/GPX/1/1"'
        self.assertFalse(has_remote_url(namespace, gpx_export=True))
        self.assertTrue(has_remote_url(namespace))
        self.assertTrue(has_remote_url('URL(string: "http://www.topografix.com/GPX/1/1")', gpx_export=True))
        self.assertTrue(has_remote_url(namespace + ' https://example.invalid', gpx_export=True))

    def test_remote_font_rejected(self):
        self.assertTrue(check_css('src:url(https://example.invalid/font.woff2)', self.root, self.root))

    def test_relative_escape_rejected(self):
        self.assertTrue(check_resource('../private.txt', self.root, self.root))

    def test_remote_image_and_prefetch_rejected(self):
        parser = ResourceParser(self.root, self.root)
        parser.feed('<img src="//example.invalid/photo.png"><link rel="preconnect" href="https://example.invalid">')
        self.assertGreaterEqual(len(parser.errors), 2)

    def test_normal_external_link_is_not_a_connection(self):
        parser = ResourceParser(self.root, self.root)
        parser.feed('<a href="https://github.com/adriaandotcom/places-app">Source</a>')
        self.assertEqual(parser.errors, [])

    def test_remote_srcset_and_css_import_rejected(self):
        parser = ResourceParser(self.root, self.root)
        parser.feed('<img srcset="https://example.invalid/a.png 2x">')
        self.assertTrue(parser.errors)
        self.assertTrue(check_css('@import "https://example.invalid/style.css";', self.root, self.root))

    def test_map_downloads_allow_only_bundled_release_assets(self):
        root = Path(__file__).resolve().parents[2]
        packs = json.loads((root / 'apps/ios/Places/Resources/OfflineMaps/packs.json').read_text())
        self.assertEqual(check_map_manifest(packs), [])
        for change in [dict(url=packs[0]['url'] + '?location=private'), dict(url='https://example.invalid/world.pmtiles'),
                       dict(sha256='missing'), dict(bytes=100_000_001), dict(minZoom=1), dict(version='../main')]:
            bad = deepcopy(packs)
            bad[0].update(change)
            self.assertTrue(check_map_manifest(bad), change)


if __name__ == '__main__':
    unittest.main()

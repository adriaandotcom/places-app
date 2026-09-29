import copy
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'maps'))
from publish_maps import merge_catalog, validate_entry, Storage
from build_lite import DETAIL_ZOOMS, keep_feature
from build_country import extract_source


def country(identifier='greece', date='20260925', version='123.1'):
    entry = dict(id=identifier, name=identifier.title(), bounds=[20, 35, 28, 42], countryCode=None)
    entry['variants'] = [dict(id=identifier, name=entry['name'], bounds=entry['bounds'], detail=detail,
        version=version, sourceDate=date, updatedAt='2026-09-28T10:00:00Z', bytes=1024, sha256='a' * 64,
        minZoom=7, maxZoom=zoom, url=f'https://places-app.b-cdn.net/maps/{identifier}/{version}/{detail}.pmtiles')
        for detail, zoom in DETAIL_ZOOMS.items()]
    return entry


class MapPublicationTests(unittest.TestCase):
    def test_source_retry_discards_partial_files_and_only_promotes_verified_download(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'greece.pmtiles'
            partial = source.with_suffix('.partial.pmtiles')
            attempts = 0
            def run(command, **options):
                nonlocal attempts
                if command[1] == 'extract':
                    attempts += 1
                    self.assertFalse(source.exists())
                    self.assertFalse(partial.exists())
                    self.assertEqual(options['timeout'], 1800)
                    partial.write_bytes(b'partial' if attempts == 1 else b'verified')
                    if attempts == 1: raise subprocess.TimeoutExpired(command, 600)
                else:
                    self.assertEqual(Path(command[2]).read_bytes(), b'verified')
            with patch('build_country.subprocess.run', side_effect=run), patch('build_country.time.sleep'):
                extract_source(['pmtiles', 'extract', 'https://example.invalid/source', str(source)], source, 'pmtiles')
            self.assertEqual(source.read_bytes(), b'verified')
            self.assertFalse(partial.exists())
            self.assertEqual(attempts, 2)

    def test_invalid_extraction_is_never_cached_after_retries(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'greece.pmtiles'
            def run(command, **options):
                if command[1] == 'extract': Path(command[3]).write_bytes(b'invalid')
                else: raise subprocess.CalledProcessError(1, command)
            with patch('build_country.subprocess.run', side_effect=run), patch('build_country.time.sleep'), self.assertRaises(subprocess.CalledProcessError):
                extract_source(['pmtiles', 'extract', 'https://example.invalid/source', str(source)], source, 'pmtiles')
            self.assertFalse(source.exists())
            self.assertFalse(source.with_suffix('.partial.pmtiles').exists())

    def test_publication_keeps_other_countries_and_replaces_all_variants_together(self):
        old, other, new = country(), country('netherlands'), country(version='124.1')
        index = dict(schemaVersion=1, countries=[dict(c, variants=[]) for c in (old, other)])
        result = merge_catalog(index, dict(schemaVersion=1, countries=[old, other]), [new])
        self.assertEqual(result['countries'], [new, other])
        self.assertEqual(index['countries'][0]['variants'], [])

    def test_partial_or_mismatched_release_is_rejected(self):
        for mutate in [lambda c: c['variants'].pop(),
                       lambda c: c['variants'][0].update(url='https://evil.invalid/a'),
                       lambda c: c['variants'][0].update(bytes=-1),
                       lambda c: c['variants'][0].update(sha256='bad'),
                       lambda c: c['variants'][0].update(sourceDate='20269999'),
                       lambda c: c['variants'][0].update(version='124.1'),
                       lambda c: c.update(bounds=[float('nan'), 0, 1, 1])]:
            value = country(); mutate(value)
            with self.assertRaises(ValueError): validate_entry(value)

    def test_older_source_duplicate_and_unknown_country_cannot_replace_catalog(self):
        entry = country(); index = dict(schemaVersion=1, countries=[dict(entry, variants=[])])
        for entries in [[country(date='20260924')], [entry, entry], [country('unknown')]]:
            with self.assertRaises(ValueError): merge_catalog(index, dict(countries=[entry]), entries)

    def test_failed_pack_upload_never_publishes_catalog(self):
        # The upload command has no catalog write; publication is a separate
        # dependent workflow job and only writes metadata after all uploads.
        source = Path(__file__).resolve().parents[2] / '.github/workflows/maps.yml'
        text = source.read_text()
        self.assertIn('needs: [prepare, generate]', text)
        self.assertIn('cancel-in-progress: false', text)
        self.assertIn("github.ref == 'refs/heads/main'", text)
        self.assertNotIn('pull_request:', text)

    def test_three_detail_levels_keep_transport_and_extensive_pois(self):
        self.assertTrue(keep_feature('pois', {'kind': 'station'}, 'normal'))
        self.assertTrue(keep_feature('pois', {'kind': 'aerodrome'}, 'normal'))
        self.assertFalse(keep_feature('pois', {'kind': 'restaurant'}, 'normal'))
        self.assertTrue(keep_feature('pois', {'kind': 'restaurant'}, 'extensive'))

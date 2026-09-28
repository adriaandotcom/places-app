import copy
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'maps'))
from publish_maps import merge_catalog, validate_entry, Storage
from build_lite import DETAIL_ZOOMS, keep_feature


def country(identifier='greece', date='20260925', version='123.1'):
    entry = dict(id=identifier, name=identifier.title(), bounds=[20, 35, 28, 42], countryCode=None)
    entry['variants'] = [dict(id=identifier, name=entry['name'], bounds=entry['bounds'], detail=detail,
        version=version, sourceDate=date, updatedAt='2026-09-28T10:00:00Z', bytes=1024, sha256='a' * 64,
        minZoom=7, maxZoom=zoom, url=f'https://places-app.b-cdn.net/maps/{identifier}/{version}/{detail}.pmtiles')
        for detail, zoom in DETAIL_ZOOMS.items()]
    return entry


class MapPublicationTests(unittest.TestCase):
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

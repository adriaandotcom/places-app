import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('catalog_builder', Path(__file__).parents[1] / 'build_place_catalog.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)

class CatalogBuilderTests(unittest.TestCase):
    def feature(self, **properties):
        return dict(id='synthetic', geometry=dict(type='Point', coordinates=[27.1, 36.8]),
                    properties=dict(names=dict(primary='Καφές', common={'en': 'Coffee'}),
                                    taxonomy=dict(primary='cafe'), **properties))

    def test_filters_and_aliases(self):
        bbox = builder.PACKS[1][2]
        item = builder.record(self.feature(), bbox)
        self.assertEqual(item[1], 'Coffee')
        self.assertIn('καφεσ', item[7])
        self.assertIn('Καφές', item[6])
        self.assertIsNone(builder.record(self.feature(operating_status='permanently_closed'), bbox))
        item = self.feature(); item['properties']['names'] = {}
        self.assertIsNone(builder.record(item, bbox))
        item = self.feature(); item['geometry']['coordinates'] = [float('nan'), 36.8]
        self.assertIsNone(builder.record(item, bbox))
        self.assertIsNone(builder.record(self.feature(), builder.PACKS[0][2]))
        self.assertIsNone(builder.record(self.feature(addresses=[{'country': 'TR'}]), bbox, 'GR'))
        item = self.feature(); item['geometry']['coordinates'] = []
        self.assertIsNone(builder.record(item, bbox))

    def test_bundle_integrity_and_search(self):
        import hashlib
        manifest = json.loads((builder.OUTPUT / 'manifest.json').read_text())
        self.assertEqual({p['id'] for p in manifest}, {'amsterdam', 'kos'})
        for pack in manifest:
            file = builder.OUTPUT / pack['filename']
            self.assertEqual(hashlib.sha256(file.read_bytes()).hexdigest(), pack['sha256'])
            with sqlite3.connect(f'file:{file}?mode=ro', uri=True) as db:
                self.assertEqual(db.execute('PRAGMA quick_check').fetchone()[0], 'ok')
                self.assertEqual(db.execute('PRAGMA user_version').fetchone()[0], 2)
                self.assertEqual(db.execute('SELECT count(*) FROM places').fetchone()[0], pack['count'])
                self.assertGreater(pack['count'], 100)
                self.assertTrue(db.execute("SELECT rowid FROM search WHERE search MATCH 'hotel*' LIMIT 1").fetchone())
                west, south, east, north = pack['bounds']
                self.assertEqual(db.execute('SELECT count(*) FROM places WHERE latitude NOT BETWEEN ? AND ? OR longitude NOT BETWEEN ? AND ?', (south,north,west,east)).fetchone()[0], 0)

    def test_major_venues_preserve_source_ids_and_aliases(self):
        feature = self.feature()
        feature['id'] = 'b2ee52ea-3b09-439e-928b-bdbf168ded5e'
        feature['properties']['names'] = {'primary': 'Κρατικός Αερολιμένας Κω Ιπποκράτης'}
        feature['properties']['taxonomy'] = {'primary': 'airport'}
        item = builder.record(feature, builder.PACKS[1][2])
        self.assertEqual(item[0], feature['id'])
        self.assertEqual(item[1], 'Kos Airport “Ippokratis”')
        self.assertIn('κρατικοσ', item[7])
        self.assertIn('hippocrates', item[7])
        self.assertEqual(item[9], 2)
        feature['id'] = 'synthetic-gate'
        feature['properties']['names'] = {'primary': 'Gate 2'}
        self.assertEqual(builder.record(feature, builder.PACKS[1][2])[9], 0)
        self.assertEqual(builder.importance('history_museum'), 1)

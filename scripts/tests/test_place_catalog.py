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
                self.assertEqual(db.execute('SELECT count(*) FROM places').fetchone()[0], pack['count'])
                self.assertGreater(pack['count'], 100)
                self.assertTrue(db.execute("SELECT rowid FROM search WHERE search MATCH 'hotel*' LIMIT 1").fetchone())
                west, south, east, north = pack['bounds']
                self.assertEqual(db.execute('SELECT count(*) FROM places WHERE latitude NOT BETWEEN ? AND ? OR longitude NOT BETWEEN ? AND ?', (south,north,west,east)).fetchone()[0], 0)

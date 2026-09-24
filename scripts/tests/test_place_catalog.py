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
                self.assertEqual(db.execute('PRAGMA user_version').fetchone()[0], 3)
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
        self.assertEqual(item[10], 0)  # Naming corrections confer no ranking advantage.
        feature['id'] = 'synthetic-gate'
        feature['properties']['names'] = {'primary': 'Gate 2'}
        self.assertEqual(builder.record(feature, builder.PACKS[1][2])[10], 0)

    def test_context_supports_any_venue_but_not_streets_or_self_duplicates(self):
        def row(key, name, address='', category='unlisted_category', latitude=36.8, confidence=0.9):
            return (key, name, address, latitude, 27.1, category, json.dumps([name]), name, '[]', confidence, 0, 0, address, 'Test City')
        records = dict([
            ('venue', row('venue', 'Willow Centre')),
            ('coffee', row('coffee', 'Coffee Stop', 'Willow Centre')),
            ('tickets', row('tickets', 'Tickets', 'Willow Centre')),
            ('far', row('far', 'Far shop', 'Willow Centre', latitude=37.0)),
            ('street', row('street', 'Willow Street')),
            ('a', row('a', 'One', 'Willow Street 10')),
            ('b', row('b', 'Two', 'Willow Street 20')),
            ('city', row('city', 'Test City')),
            ('low', row('low', 'Unreliable', 'Willow Centre', confidence=0.2)),
        ])
        ranked = builder.add_venue_context(records)
        self.assertEqual(ranked['venue'][10], 2)
        self.assertEqual(ranked['street'][10], 0)
        self.assertEqual(ranked['city'][10], 0)
        self.assertEqual(ranked['coffee'][10], 0)

    def test_partial_street_words_and_duplicate_sites_are_not_venue_evidence(self):
        def row(key, name, latitude=36.8, address=''):
            return (key, name, address, latitude, 27.1, 'shop', json.dumps([name]), name, '[]', 0.9, 0, 0, address, '')
        rows = {
            'near': row('near', 'Willow Centre'), 'far': row('far', 'Willow Centre', latitude=36.81),
            'shop': row('shop', 'Shop', address='Willow Centre'),
            'green': row('green', 'Green'), 'street': row('street', 'Other', address='Green Street 12'),
            'canal': row('canal', 'Canal'), 'on-canal': row('on-canal', 'On the canal', address='Canal'),
            'number-one': row('number-one', 'One', address='Canal 10'),
            'number-two': row('number-two', 'Two', address='Canal 20'),
        }
        ranked = builder.add_venue_context(rows)
        self.assertEqual(ranked['near'][10], 1)
        self.assertEqual(ranked['far'][10], 0)
        self.assertEqual(ranked['green'][10], 0)
        self.assertEqual(ranked['canal'][10], 0)

    def test_repeated_chain_names_do_not_promote_every_branch(self):
        def row(key, name, latitude, address=''):
            return (key, name, address, latitude, 27.1, 'shop', json.dumps([name]), name, '[]', 0.9, 0, 0, address, '')
        rows = {f'branch-{i}': row(f'branch-{i}', 'Willow Shops', 36.8 + i * 0.015) for i in range(3)}
        rows.update({f'reference-{i}': row(f'reference-{i}', f'Willow Shops branch {i}', 36.8 + i * 0.015) for i in range(3)})
        ranked = builder.add_venue_context(rows)
        self.assertTrue(all(ranked[f'branch-{i}'][10] == 0 for i in range(3)))

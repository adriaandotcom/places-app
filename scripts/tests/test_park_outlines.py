import gzip
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'maps'))
from build_areas import geometry_commands, build_areas
from build_lite import field, integer


def commands(points, close=True):
    values, x, y = [], 0, 0
    for index, (px, py) in enumerate(points):
        dx, dy = px - x, py - y
        values.extend([9 if index == 0 else 10, (dx << 1) ^ (dx >> 63), (dy << 1) ^ (dy >> 63)])
        x, y = px, py
    if close: values.append(15)
    return b''.join(integer(v) for v in values)


def layer(name, geometry, identifier=42):
    feature = field(1, identifier) + field(2, bytes([0, 0, 1, 1])) + field(3, 3 if name == 'landuse' else 1) + field(4, geometry)
    return field(3, field(1, name.encode()) + field(2, feature) + field(3, b'kind') + field(3, b'name')
                 + field(4, field(1, b'park')) + field(4, field(1, b'Fixture park')) + field(5, 4096) + field(15, 2))


class ParkOutlineTests(unittest.TestCase):
    def test_geometry_decodes_negative_deltas_without_joining_rings(self):
        outer = [(2, 2), (8, 2), (8, 8), (2, 8)]
        self.assertEqual(geometry_commands(commands(outer)), [outer])
        hole = bytes([9, 2, 9, 10, 0, 8, 10, 8, 0, 10, 0, 7, 15])
        self.assertEqual(geometry_commands(commands(outer) + hole), [outer, [(3, 3), (3, 7), (7, 7), (7, 3)]])
        with self.assertRaises(ValueError): geometry_commands(bytes([11]))

    def test_tile_fragments_are_joined_and_source_ids_are_removed(self):
        try:
            from pmtiles.writer import Writer
            from pmtiles.tile import Compression, TileType, zxy_to_tileid
            import shapely
        except ImportError:
            self.skipTest('Map generation dependencies are installed separately')
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / 'source.pmtiles'
            header = dict(tile_type=TileType.MVT, tile_compression=Compression.GZIP,
                          min_zoom=12, max_zoom=12, min_lon_e7=0, min_lat_e7=-10000000,
                          max_lon_e7=10000000, max_lat_e7=0, center_zoom=12, center_lon_e7=0, center_lat_e7=0)
            with source.open('wb') as stream:
                writer = Writer(stream)
                tiles = [
                    (2048, layer('landuse', commands([(2000, 1000), (4096, 1000), (4096, 3000), (2000, 3000)]))
                     + layer('pois', commands([(2100, 1100)], close=False))),
                    (2049, layer('landuse', commands([(0, 1000), (2000, 1000), (2000, 3000), (0, 3000)]))),
                ]
                for x, tile in sorted(tiles, key=lambda t: zxy_to_tileid(12, t[0], 2048)):
                    writer.write_tile(zxy_to_tileid(12, x, 2048), gzip.compress(tile, mtime=0))
                writer.finalize(header, dict(version='4.0'))
            result = build_areas(source)
            self.assertEqual(result['version'], 1)
            self.assertEqual(len(result['parks']), 1)
            park = result['parks'][0]
            self.assertEqual(park['name'], 'Fixture park')
            self.assertEqual(len(park['area']['polygons']), 1)
            self.assertNotEqual(park['id'], '42')
            self.assertEqual(len(park['id']), 24)
            outer = park['area']['polygons'][0]['outer']
            self.assertGreater(max(p[0] for p in outer) - min(p[0] for p in outer), 0.08)
            self.assertEqual(result, build_areas(source))

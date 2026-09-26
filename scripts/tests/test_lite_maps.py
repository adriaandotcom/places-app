import importlib.util
from collections import Counter
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('build_lite', Path(__file__).resolve().parents[1] / 'maps/build_lite.py')
lite = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lite)


class LiteMapTests(unittest.TestCase):
    def layer(self, name='roads', kind='highway'):
        tags = bytes([0, 0, 1, 1, 2, 2])
        geometry = bytes([9, 20, 30, 18, 2, 4, 2, 4])
        feature = lite.field(1, 123456789) + lite.field(2, tags) + lite.field(3, 2) + lite.field(4, geometry)
        values = [lite.field(1, kind.encode()), lite.field(1, 'Αθήνα'.encode()), lite.field(1, b'unused value')]
        return (lite.field(1, name.encode()) + lite.field(2, feature)
                + b''.join(lite.field(3, k.encode()) for k in ['kind', 'name', 'private_unused_attribute'])
                + b''.join(lite.field(4, v) for v in values) + lite.field(5, 4096) + lite.field(15, 2)), geometry

    def test_geometry_and_greek_labels_survive_but_ids_and_unused_attributes_do_not(self):
        source, geometry = self.layer()
        result = lite.strip_layer(source, Counter())
        fields = list(lite.fields(result))
        self.assertEqual([v for k, v in fields if k == 3], [b'kind', b'name'])
        feature = dict(lite.fields(next(v for k, v in fields if k == 2)))
        self.assertNotIn(1, feature)
        self.assertEqual(feature[4], geometry)
        self.assertIn('Αθήνα'.encode(), result)
        self.assertNotIn(b'unused value', result)
        self.assertEqual(lite.strip_layer(result, Counter()), result)

    def test_unwanted_layers_and_minor_paths_are_removed(self):
        for layer, kind in [('buildings', 'building'), ('pois', 'restaurant'), ('roads', 'path')]:
            source, _ = self.layer(layer, kind)
            self.assertIsNone(lite.strip_layer(source, Counter()))

    def test_malformed_protobuf_is_rejected(self):
        for data in [b'\x80', b'\x1a\x10\x01', b'\x00', b'\x0f']:
            with self.assertRaises(ValueError):
                list(lite.fields(data))

    def test_varints_round_trip(self):
        for value in [0, 127, 128, 16384, 2**63 - 1]:
            self.assertEqual(lite.varint(lite.integer(value), 0), (value, len(lite.integer(value))))


if __name__ == '__main__':
    unittest.main()

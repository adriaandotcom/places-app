#!/usr/bin/env python3
"""Validate measured release archives (build-only pmtiles==3.7.0 required)."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
from pmtiles.reader import MmapSource, Reader, all_tiles
from build_lite import fields, LAYERS, KEYS


def verify(directory):
    manifest = Path(__file__).resolve().parents[2] / 'apps/ios/Places/Resources/OfflineMaps/packs.json'
    for pack in json.loads(manifest.read_text()):
        source = directory / (pack['id'] + '.pmtiles')
        with source.open('rb') as file:
            if source.stat().st_size != pack['bytes'] or hashlib.file_digest(file, 'sha256').hexdigest() != pack['sha256']:
                raise ValueError('Release size or checksum differs: ' + pack['id'])
            read = MmapSource(file)
            header = Reader(read).header()
            assert header['min_zoom'] == pack['minZoom'] and header['max_zoom'] == pack['maxZoom']
            tiles = features = greek = 0
            for _, compressed in all_tiles(read):
                tiles += 1
                for key, layer in fields(gzip.decompress(compressed)):
                    assert key == 3
                    content = list(fields(layer))
                    name = next(v.decode() for k, v in content if k == 1)
                    assert name in LAYERS
                    assert all(v.decode() in KEYS for k, v in content if k == 3)
                    for k, value in content:
                        if k == 2:
                            features += 1
                            assert all(n != 1 for n, _ in fields(value)), 'Source feature ID retained'
                        if k == 4:
                            for n, text in fields(value):
                                if n == 1 and any('\u0370' <= ch <= '\u03ff' for ch in text.decode()):
                                    greek += 1
            if pack['id'] == 'greece':
                assert greek > 0, 'Local Greek names were lost'
            print(json.dumps(dict(pack=pack['id'], bytes=pack['bytes'], tiles=tiles, features=features, greekLabels=greek)))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    verify(parser.parse_args().directory)

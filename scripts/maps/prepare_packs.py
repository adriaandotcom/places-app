#!/usr/bin/env python3
"""Reproduce Places Lite outside normal CI; needs pmtiles CLI 1.31.2 and Python pmtiles==3.7.0.

Usage: python prepare_packs.py --pmtiles /path/to/pmtiles --work /tmp/places-map-build
This downloads only selected tiles, never the full planet. Outputs stay outside Git.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request
from build_lite import build


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pmtiles', required=True, type=Path)
    parser.add_argument('--work', required=True, type=Path)
    args = parser.parse_args()
    lock = json.loads(Path(__file__).with_name('source-lock.json').read_text())
    args.work.mkdir(parents=True, exist_ok=True)
    raw = args.work / 'source'; raw.mkdir(exist_ok=True)
    output = args.work / 'packs'; output.mkdir(exist_ok=True)
    boundaries = raw / 'countries.geojson'
    if not boundaries.exists():
        with urllib.request.urlopen(lock['boundaries']['url']) as response:
            boundaries.write_bytes(response.read())
    if hashlib.sha256(boundaries.read_bytes()).hexdigest() != lock['boundaries']['sha256']:
        raise ValueError('Country boundary source checksum mismatch')
    countries = json.loads(boundaries.read_text())
    for region, code in [('world', None), ('netherlands', 'NLD'), ('greece', 'GRC')]:
        source = raw / (region + '.pmtiles')
        command = [str(args.pmtiles), 'extract', lock['tiles']['url'], str(source), '--download-threads=4', '-q']
        if code:
            features = [dict(type='Feature', properties={}, geometry=feature['geometry']) for feature in countries['features']
                        if feature['properties'].get('ADM0_A3') == code]
            if len(features) != 1:
                raise ValueError('Unexpected country outline count')
            polygon = raw / (region + '.geojson')
            polygon.write_text(json.dumps(dict(type='FeatureCollection', features=features)))
            command += ['--region=' + str(polygon), '--minzoom=7', '--maxzoom=12']
        else:
            command += ['--maxzoom=6']
        if not source.exists():
            subprocess.run(command, check=True)
        build(source, output / (region + '.pmtiles'), region)
        expected = next(item for item in lock['measurements'] if item['region'] == region)
        actual = json.loads((output / (region + '.json')).read_text())
        if (actual['bytes'], actual['sha256']) != (expected['bytes'], expected['sha256']):
            raise ValueError('Output differs from the pinned release; do not replace existing release assets')


if __name__ == '__main__':
    main()

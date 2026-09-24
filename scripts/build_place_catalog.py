#!/usr/bin/env python3
"""Build bundled, public POI data. Never point this tool at private history exports.

Fetch inputs outside the repository using the pinned official client:
uv run --no-project --with-requirements scripts/place_catalog_requirements.txt \
  overturemaps download --no-stac \
  --connect_timeout=30 --request_timeout=300 --release=2026-09-23.0 --type=place -f geojsonseq --bbox=W,S,E,N -o INPUT
Then: python3 scripts/build_place_catalog.py /path/to/input-directory
Inputs must be named amsterdam.geojsonseq and kos.geojsonseq.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import sqlite3
import unicodedata

RELEASE = '2026-09-23.0'
PACKS = [('amsterdam', 'Amsterdam & surroundings', [4.65, 52.25, 5.10, 52.50]),
         ('kos', 'Kos island', [26.90, 36.65, 27.45, 36.96])]
OUTPUT = Path(__file__).resolve().parents[1] / 'packages/PlacesCore/Sources/PlacesCore/Resources/PlaceCatalog'


def normalize(text):
    return ''.join(c for c in unicodedata.normalize('NFKD', text.lower())
                   if not unicodedata.combining(c)).replace('ς', 'σ').replace('ß', 'ss')


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


def record(feature, bbox, country=None):
    p = feature.get('properties') or {}
    geometry = feature.get('geometry') or {}
    if geometry.get('type') != 'Point' or p.get('operating_status') in ('closed', 'permanently_closed', 'temporarily_closed'):
        return None
    coordinates = geometry.get('coordinates')
    if not isinstance(coordinates, list) or len(coordinates) < 2:
        return None
    lon, lat = coordinates[:2]
    if not all(isinstance(n, (int, float)) and math.isfinite(n) for n in (lat, lon)):
        return None
    west, south, east, north = bbox
    if not (west <= lon <= east and south <= lat <= north):
        return None
    names = p.get('names') or {}
    primary = (names.get('primary') or '').strip()
    if not primary:
        return None
    common = names.get('common') or {}
    name = common.get('en') or primary
    aliases = sorted(set(strings(names)))
    addresses = p.get('addresses') or []
    countries = {a.get('country') for a in addresses if a.get('country')}
    if country and countries and country not in countries:
        return None
    address = ''
    if addresses:
        a = addresses[0]
        address = ', '.join(str(a[k]) for k in ('freeform', 'locality', 'postcode') if a.get(k))
    taxonomy = p.get('taxonomy') or p.get('categories') or {}
    category = taxonomy.get('primary') or p.get('basic_category') or ''
    source_id = feature.get('id') or p.get('id')
    if not source_id:
        return None
    return (source_id, name, address, lat, lon, category,
            json.dumps(aliases, ensure_ascii=False), normalize(' '.join([name, *aliases, address, category.replace('_', ' ')])),
            json.dumps([{key: value for key, value in source.items() if key in ('dataset', 'license', 'record_id')}
                        for source in (p.get('sources') or [])], ensure_ascii=False, sort_keys=True, separators=(',', ':')))


def build(source, destination=OUTPUT):
    destination.mkdir(parents=True, exist_ok=True)
    packs = []
    for key, title, bbox in PACKS:
        rows = {}
        with (source / f'{key}.geojsonseq').open() as stream:
            for line in stream:
                if line.strip():
                    item = record(json.loads(line.lstrip('\x1e')), bbox, 'GR' if key == 'kos' else 'NL')
                    if item:
                        rows[item[0]] = item
        if not rows:
            raise ValueError(f'No usable public places for {key}; refusing an empty pack')
        target = destination / f'{key}.sqlite'
        target.unlink(missing_ok=True)
        with sqlite3.connect(target) as db:
            db.executescript('''PRAGMA user_version=1;
                CREATE TABLE places (id TEXT PRIMARY KEY, name TEXT NOT NULL, address TEXT NOT NULL,
                latitude REAL NOT NULL, longitude REAL NOT NULL, category TEXT NOT NULL,
                aliases TEXT NOT NULL, searchText TEXT NOT NULL, sources TEXT NOT NULL);
                CREATE INDEX places_location ON places(latitude, longitude);
                CREATE VIRTUAL TABLE search USING fts5(searchText, content=places, content_rowid=rowid,
                  tokenize='unicode61 remove_diacritics 2');''')
            db.executemany('INSERT INTO places VALUES (?,?,?,?,?,?,?,?,?)', [rows[k] for k in sorted(rows)])
            db.execute("INSERT INTO search(search) VALUES ('rebuild')")
            db.commit()
            db.execute('VACUUM')
        packs.append(dict(id=key, name=title, bounds=bbox, schemaVersion=1, release=RELEASE,
                          count=len(rows), filename=target.name, attribution="Overture Maps Foundation and contributors; see LICENSES.txt",
                          sha256=hashlib.sha256(target.read_bytes()).hexdigest()))
        print(f'{title}: {len(rows):,} places, {target.stat().st_size:,} bytes')
    (destination / 'manifest.json').write_text(json.dumps(packs, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    args = parser.parse_args()
    build(args.source)

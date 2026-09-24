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
import re
from collections import defaultdict
from pathlib import Path
import sqlite3
import unicodedata

RELEASE = '2026-09-23.0'
PACKS = [('amsterdam', 'Amsterdam & surroundings', [4.65, 52.25, 5.10, 52.50]),
         ('kos', 'Kos island', [26.90, 36.65, 27.45, 36.96])]
OUTPUT = Path(__file__).resolve().parents[1] / 'packages/PlacesCore/Sources/PlacesCore/Resources/PlaceCatalog'

# Display-name/translation corrections only; these IDs carry no ranking weight.
# Names verified against https://www.kgs-airport.gr/ and https://www.schiphol.nl/en/.
NAME_CORRECTIONS = {
    'b2ee52ea-3b09-439e-928b-bdbf168ded5e': ('Kos Airport “Ippokratis”', ['Kos Airport', 'Kos International Airport', 'Hippocrates', 'KGS', 'Flughafen Kos', 'Luchthaven Kos']),
    '8499bdcc-37ee-4331-80be-57497c99e288': ('Amsterdam Airport Schiphol', ['Schiphol Airport', 'Luchthaven Schiphol', 'AMS']),
}


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
    if source_id in NAME_CORRECTIONS:
        name, extra_aliases = NAME_CORRECTIONS[source_id]
        aliases = sorted(set([*aliases, *extra_aliases, name]))
    confidence = p.get("confidence")
    confidence = min(1, max(0, confidence)) if isinstance(confidence, (int, float)) and math.isfinite(confidence) else 0.5
    return (source_id, name, address, lat, lon, category,
            json.dumps(aliases, ensure_ascii=False), normalize(' '.join([name, *aliases, address, category.replace('_', ' ')])),
            json.dumps([{key: value for key, value in source.items() if key in ('dataset', 'license', 'record_id')}
                        for source in (p.get('sources') or [])], ensure_ascii=False, sort_keys=True, separators=(',', ':')), confidence, 0, 0,
            str(addresses[0].get('freeform') or '') if addresses else '',
            str(addresses[0].get('locality') or '') if addresses else '')


def words(text):
    return re.findall(r"[^\W_]+", normalize(text), re.UNICODE)


def distance(a, b):
    lat1, lat2 = math.radians(a[3]), math.radians(b[3])
    h = math.sin((lat2 - lat1) / 2)**2 + math.cos(lat1) * math.cos(lat2) * math.sin(math.radians(b[4] - a[4]) / 2)**2
    return 6371000 * 2 * math.asin(min(1, math.sqrt(h)))


def add_venue_context(rows):
    # Infer venue context from full names mentioned in OTHER nearby POI addresses.
    # This applies to any category (stations, campuses, malls, museums, etc.).
    # Never use locality/postcode, which would promote city names indiscriminately.
    localities = {tuple(words(row[13])) for row in rows.values() if row[13]}
    names = defaultdict(set)
    for key, row in rows.items():
        for alias in json.loads(row[6]):
            tokens = tuple(words(alias))
            if 1 <= len(tokens) <= 10 and len(''.join(tokens)) >= 5 and tokens not in localities:
                names[tokens].add(key)
    supporters = defaultdict(set)
    radii = defaultdict(float)
    street_uses = defaultdict(int)
    for key, row in rows.items():
        tokens = words(row[12])
        address_parts = {tuple(words(part)) for part in re.split(r'[,;\n]', row[12])}
        matches = set()
        for start in range(len(tokens)):
            for count in range(1, min(10, len(tokens) - start) + 1):
                phrase = tuple(tokens[start:start + count])
                candidates = names.get(phrase, ())
                if start + count < len(tokens) and tokens[start + count][0].isdigit():
                    for candidate in candidates: street_uses[candidate] += 1
                # A lone word inside a longer street name is not a venue.
                elif candidates and (count > 1 or phrase in address_parts):
                    # Resolve repeated names to the closest site. Prefer the
                    # better source when its point is in the same immediate area.
                    nearest = min(distance(row, rows[c]) for c in candidates)
                    matches.add(max((c for c in candidates if distance(row, rows[c]) <= nearest + 150),
                                    key=lambda c: (rows[c][9], c)))
        for candidate in matches - {key}:
            if tuple(words(row[1])) in {tuple(words(alias)) for alias in json.loads(rows[candidate][6])}:
                continue  # Same-name duplicates do not corroborate their own venue.
            if row[9] >= 0.6 and distance(row, rows[candidate]) <= 3000:
                # Duplicate source listings should not multiply the same evidence.
                supporters[candidate].add((tuple(words(row[1])), round(row[3], 3), round(row[4], 3)))
                radii[candidate] = max(radii[candidate], distance(row, rows[candidate]))
    # A business named after its street must not inherit the whole street's importance.
    return {key: (*row[:10], 0 if street_uses[key] >= 2 else len(supporters[key]),
                  radii[key], row[12], row[13]) for key, row in rows.items()}


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
        rows = add_venue_context(rows)
        target = destination / f'{key}.sqlite'
        target.unlink(missing_ok=True)
        with sqlite3.connect(target) as db:
            db.executescript('''PRAGMA user_version=3;
                CREATE TABLE places (id TEXT PRIMARY KEY, name TEXT NOT NULL, address TEXT NOT NULL,
                latitude REAL NOT NULL, longitude REAL NOT NULL, category TEXT NOT NULL,
                aliases TEXT NOT NULL, searchText TEXT NOT NULL, sources TEXT NOT NULL, confidence REAL NOT NULL, venueReferences INTEGER NOT NULL, contextRadius REAL NOT NULL);
                CREATE INDEX places_location ON places(latitude, longitude);
                CREATE VIRTUAL TABLE search USING fts5(searchText, content=places, content_rowid=rowid,
                  tokenize='unicode61 remove_diacritics 2');''')
            db.executemany('INSERT INTO places VALUES (?,?,?,?,?,?,?,?,?,?,?,?)', [rows[k][:-2] for k in sorted(rows)])
            db.execute("INSERT INTO search(search) VALUES ('rebuild')")
            db.commit()
            db.execute('VACUUM')
        packs.append(dict(id=key, name=title, bounds=bbox, schemaVersion=3, release=RELEASE,
                          count=len(rows), filename=target.name, attribution="Overture Maps Foundation and contributors; see LICENSES.txt",
                          sha256=hashlib.sha256(target.read_bytes()).hexdigest()))
        print(f'{title}: {len(rows):,} places, {target.stat().st_size:,} bytes')
    (destination / 'manifest.json').write_text(json.dumps(packs, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    args = parser.parse_args()
    build(args.source)

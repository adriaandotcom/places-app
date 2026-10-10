#!/usr/bin/env python3
"""Package an already-built Valhalla 3.9.1 graph. Only public routing data belongs here."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--graph', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--name', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--bounds', type=float, nargs=4, metavar=('SOUTH', 'WEST', 'NORTH', 'EAST'), required=True)
    parser.add_argument('--source', required=True)
    parser.add_argument('--source-sha256', required=True)
    parser.add_argument('--catalog', type=Path, required=True, help='Write this reviewed graph to the bundled allowlist')
    args = parser.parse_args()
    south, west, north, east = args.bounds
    if not (-90 <= south < north <= 90 and -180 <= west < east <= 180):
        parser.error('Invalid bounds')
    if args.output.exists():
        parser.error('Output already exists; choose a new version/path')
    pack = dict(name=args.name, version=args.version, engine='3.9.1', bytes=args.graph.stat().st_size,
                sha256=digest(args.graph), south=south, west=west, north=north, east=east)
    notice = f'''Places Valhalla routing pack: {args.name}
Version: {args.version}; Valhalla engine 3.9.1
Graph bytes: {pack['bytes']}; SHA-256: {pack['sha256']}
Public OSM source: {args.source}
OSM source SHA-256: {args.source_sha256}

Contains a routing graph, not your location history. Nothing is uploaded when
Places matches points against it. Import through Location collectors in Places.
The graph needs {pack['bytes'] / 1_000_000:.1f} MB after installation, in addition
to this ZIP. It is excluded from device backups and can be deleted in the app.
Only matching traces inside this region can use this graph. Missing road/path
data and sparse GPS observations can produce incorrect or incomplete estimates.
Elapsed times come from the original measurements; routing ETAs are not history.
This experiment omits administrative/timezone/elevation enrichment. It does not
support public-transport timetable matching or live traffic.

Routing data © OpenStreetMap contributors, licensed under ODbL 1.0:
https://www.openstreetmap.org/copyright
https://opendatacommons.org/licenses/odbl/1-0/
Original database extract: {args.source}
Build instructions and pinned tools: VALHALLA.md in the Places source repository.
'''
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as archive:
        archive.writestr('pack.json', json.dumps(pack, indent=2) + '\n')
        archive.write(args.graph, 'tiles.tar')
        archive.writestr('README.txt', notice)
    args.catalog.write_text(json.dumps([pack], indent=2) + '\n')
    print(json.dumps(dict(pack=pack, zipBytes=args.output.stat().st_size, zipSHA256=digest(args.output)), indent=2))


if __name__ == '__main__':
    main()

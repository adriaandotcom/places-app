#!/usr/bin/env python3
"""Publish a checksum-pinned public routing ZIP to the existing Bunny zone."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts/maps'))
from publish_maps import Storage

CATALOG = ROOT / 'packages/PlacesRouting/Sources/PlacesRouting/Resources/downloads.json'


def descriptor(country):
    entries = json.loads(CATALOG.read_text())
    source = next((e for e in entries if e['country'] == country), None)
    if source is None or not re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', country):
        raise ValueError('Choose a bundled routing country')
    pack = source['pack']
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+)*', pack['version']) or not re.fullmatch(r'[A-Za-z -]+', pack['name']):
        raise ValueError('Invalid routing identity')
    if source['bytes'] <= 0 or not re.fullmatch(r'[0-9a-f]{64}', source['sha256']):
        raise ValueError('Invalid measured archive metadata')
    graphs = json.loads(CATALOG.with_name('packs.json').read_text())
    if pack not in graphs: raise ValueError('Routing graph is not approved by the app')
    return source


def public_url(source):
    return f"https://places-app.b-cdn.net/maps/routing/{source['country']}/{source['pack']['version']}/valhalla.zip"


def verify_file(file, source):
    with file.open('rb') as stream:
        if file.stat().st_size != source['bytes'] or hashlib.file_digest(stream, 'sha256').hexdigest() != source['sha256']:
            raise ValueError('Routing ZIP differs from the bundled size/checksum')


def verify_public(source):
    request = urllib.request.Request(public_url(source), headers={'User-Agent': 'Places', 'Cache-Control': 'no-cache'})
    with urllib.request.urlopen(request, timeout=60) as response:
        if response.status != 200 or response.geturl() != public_url(source): raise ValueError('Unexpected public routing response')
        digest = hashlib.sha256(); count = 0
        while chunk := response.read(1024 * 1024):
            count += len(chunk)
            if count > source['bytes']: raise ValueError('Public routing archive is too large')
            digest.update(chunk)
        if count != source['bytes'] or digest.hexdigest() != source['sha256']:
            raise ValueError('Public routing archive checksum mismatch')


def publish(file, source, storage):
    verify_file(file, source)
    path = f"/maps/routing/{source['country']}/{source['pack']['version']}/valhalla.zip"
    entries = json.loads(storage.request('GET', path.rsplit('/', 1)[0] + '/') or b'[]')
    if not any(entry.get('ObjectName') == 'valhalla.zip' or entry.get('FileName') == 'valhalla.zip' for entry in entries):
        with file.open('rb') as stream:
            storage.request('PUT', path, stream, source['bytes'], source['sha256'], 'application/zip')
    # Never overwrite an existing immutable object. Its actual public bytes must agree.
    for attempt in range(12):
        try:
            verify_public(source)
            print(f"Published and verified {public_url(source)} ({source['bytes']} bytes)", flush=True)
            return
        except urllib.error.HTTPError as error:
            if error.code not in (404, 502, 503) or attempt == 11: raise ValueError(f'Public routing endpoint returned HTTP {error.code}') from None
            time.sleep(10)
    raise ValueError('Public routing archive is unavailable')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--country', default='netherlands')
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--download-release', action='store_true')
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    source = descriptor(args.country)
    if args.verify_only: verify_public(source)
    else:
        if args.download_release:
            folder = ROOT / 'build/routing-publication'; folder.mkdir(parents=True, exist_ok=True)
            filename = f"Places-Valhalla-{source['pack']['name']}-{source['pack']['version']}.zip"
            subprocess.run(['gh', 'release', 'download', 'routing-' + source['pack']['version'], '--repo',
                'adriaandotcom/places-app', '--pattern', filename, '--dir', str(folder)], check=True)
            args.archive = folder / filename
        if args.archive is None: parser.error('Choose an archive or --download-release')
        publish(args.archive, source, Storage())

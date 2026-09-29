"""Join OSM park geometry from a pinned Protomaps extract for offline selection.

Use source feature IDs only during assembly. The published catalog contains
local names, geometry and opaque content IDs, and is shared by all detail levels.
"""
import gzip
import hashlib
import json
import math
from collections import defaultdict

from build_lite import fields, packed

KINDS = {'park', 'national_park', 'nature_reserve', 'garden', 'dog_park'}


def geometry_commands(data):
    values = iter(packed(data))
    x = y = 0
    rings = []
    current = []
    for command in values:
        kind, count = command & 7, command >> 3
        if kind in (1, 2):
            for _ in range(count):
                a, b = next(values), next(values)
                x += (a >> 1) ^ -(a & 1); y += (b >> 1) ^ -(b & 1)
                if kind == 1 and current:
                    rings.append(current); current = []
                current.append((x, y))
        elif kind == 7:
            if current: rings.append(current); current = []
        else:
            raise ValueError('Unsupported geometry command')
    if current: rings.append(current)
    return rings


def features(tile):
    for number, data in fields(tile):
        if number != 3: continue
        layer = list(fields(data))
        name = next(value.decode() for key, value in layer if key == 1)
        if name not in ('landuse', 'pois'): continue
        extent = next((v for k, v in layer if k == 5), 4096)
        keys = [v.decode() for k, v in layer if k == 3]
        values = [next((v.decode() for k, v in fields(v) if k == 1), None) for k, v in layer if k == 4]
        for number, feature in layer:
            if number != 2: continue
            data = dict(fields(feature)); tags = list(packed(data.get(2, b'')))
            attributes = {keys[k]: values[v] for k, v in zip(tags[::2], tags[1::2])}
            if attributes.get('kind') in KINDS and 1 in data and 4 in data:
                yield name, data[1], attributes, extent, geometry_commands(data[4])


def build_areas(source):
    from pmtiles.reader import Reader, MmapSource, all_tiles
    from shapely import make_valid, union_all
    from shapely.geometry import Polygon, Point
    shapes, names, labels = defaultdict(list), {}, {}
    with source.open('rb') as stream:
        data = MmapSource(stream)
        zoom = min(14, Reader(data).header()['max_zoom'])
        for (z, x, y), tile in all_tiles(data):
            if z != zoom: continue
            for layer, identifier, tags, extent, rings in features(gzip.decompress(tile)):
                # One common integer grid keeps neighboring tile edges identical.
                rings = [[(x * 4096 + px * 4096 / extent, y * 4096 + py * 4096 / extent) for px, py in ring] for ring in rings]
                if layer == 'pois':
                    if tags.get('name'):
                        names[identifier] = tags['name']; labels[identifier] = rings[0][0]
                    continue
                outer, holes = None, []
                for ring in rings:
                    if len(ring) < 3: continue
                    area = sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(ring, ring[1:] + ring[:1]))
                    if area > 0:
                        if outer: shapes[identifier].append(make_valid(Polygon(outer, holes)))
                        outer, holes = ring, []
                    elif outer: holes.append(ring)
                if outer: shapes[identifier].append(make_valid(Polygon(outer, holes)))
    scale = 4096 * 2**zoom
    def coordinate(point):
        return dict(latitude=round(math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * point[1] / scale)))), 6),
                    longitude=round(point[0] / scale * 360 - 180, 6))
    def ring(points):
        result = []
        for point in list(points)[:-1]:
            decoded = coordinate(point)
            value = [decoded['longitude'], decoded['latitude']]
            if not result or value != result[-1]: result.append(value)
        if result and result[-1] == result[0]: result.pop()
        return result
    parks = []
    for identifier, parts in shapes.items():
        merged = make_valid(union_all(parts).simplify(2, preserve_topology=True))
        polygons = [merged] if merged.geom_type == 'Polygon' else [g for g in getattr(merged, 'geoms', []) if g.geom_type == 'Polygon']
        polygons = [dict(outer=ring(p.exterior.coords), holes=[ring(h.coords) for h in p.interiors]) for p in polygons]
        polygons = [p for p in polygons if len(p['outer']) >= 3]
        for p in polygons: p['holes'] = [h for h in p['holes'] if len(h) >= 3]
        if not polygons or len(polygons) > 256 or sum(len(p['outer']) + sum(map(len, p['holes'])) for p in polygons) > 20_000: continue
        area = dict(polygons=polygons, sourceName='OpenStreetMap')
        digest = hashlib.sha256(json.dumps(area, sort_keys=True).encode()).hexdigest()[:24]
        center = labels.get(identifier)
        if center is None or not merged.covers(Point(center)): center = list(merged.representative_point().coords)[0]
        parks.append(dict(id=digest, name=names.get(identifier, 'Park'), coordinate=coordinate(center), area=area))
    parks = list({p['id']: p for p in parks}.values())
    result = dict(version=1, parks=sorted(parks, key=lambda p: (p['name'], p['id'])))
    if len(json.dumps(result).encode()) > 30_000_000:
        raise ValueError('Park catalog exceeds the on-device metadata limit')
    print(f'Prepared {len(parks)} offline park outlines at z{zoom}', flush=True)
    return result

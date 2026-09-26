#!/usr/bin/env python3
"""Strip a pinned Protomaps v4 extract into a local-only Places Lite archive.

Build-only dependency: pmtiles==3.7.0. Input extracts are produced by
pmtiles v1.31.2 from https://build.protomaps.com/20260925.pmtiles.
Large input/output archives must stay outside Git history.
"""
import argparse
from collections import Counter
import gzip
import hashlib
import json
from pathlib import Path
from unittest.mock import patch

VERSION = "20260925.1"
LAYERS = {"earth", "water", "landcover", "landuse", "boundaries", "places", "roads"}
KEYS = {"kind", "kind_detail", "min_zoom", "sort_rank", "name", "name:en", "population_rank", "capital", "disputed"}
PARKS = {"forest", "wood", "park", "national_park", "nature_reserve", "protected_area"}
ROADS = {"highway", "major_road", "minor_road", "rail", "ferry"}
SMALL_ROADS = {"service", "driveway", "parking_aisle", "alley", "drive-through", "emergency_access", "disused"}
ATTRIBUTION = "© OpenStreetMap contributors · Natural Earth · Protomaps"


def varint(data, pos):
    result = 0
    for shift in range(0, 70, 7):
        if pos >= len(data):
            raise ValueError("Truncated protobuf varint")
        value = data[pos]; pos += 1
        result |= (value & 127) << shift
        if value < 128:
            return result, pos
    raise ValueError("Oversized protobuf varint")


def integer(value):
    out = bytearray()
    while value > 127:
        out.append((value & 127) | 128); value >>= 7
    out.append(value)
    return bytes(out)


def field(number, value):
    if isinstance(value, int):
        return integer(number << 3) + integer(value)
    return integer((number << 3) | 2) + integer(len(value)) + value


def fields(data):
    pos = 0
    while pos < len(data):
        tag, pos = varint(data, pos)
        number, wire = tag >> 3, tag & 7
        if not number:
            raise ValueError("Invalid protobuf field")
        if wire == 0:
            value, pos = varint(data, pos)
        elif wire in (1, 2, 5):
            if wire == 2:
                length, pos = varint(data, pos)
            else:
                length = 8 if wire == 1 else 4
            if pos + length > len(data):
                raise ValueError("Truncated protobuf field")
            value = data[pos:pos + length]; pos += length
        else:
            raise ValueError("Unsupported protobuf wire type")
        yield number, value


def packed(data):
    pos = 0
    while pos < len(data):
        value, pos = varint(data, pos)
        yield value


def keep_feature(layer, attributes):
    kind = attributes.get("kind")
    detail = attributes.get("kind_detail")
    if layer == "roads":
        return kind in ROADS and detail not in SMALL_ROADS
    if layer == "landuse":
        return kind in PARKS
    if layer == "landcover":
        return kind in {"forest", "glacier"}
    if layer == "boundaries":
        return kind in {"country", "region"}
    if layer == "water":
        return detail not in {"ditch", "drain", "stream", "dock"}
    return True


def strip_layer(data, stats):
    original = list(fields(data))
    name = next(v.decode() for k, v in original if k == 1)
    if name not in LAYERS:
        return None
    keys = [v.decode() for k, v in original if k == 3]
    values = [v for k, v in original if k == 4]
    strings = [next((v.decode() for k, v in fields(value) if k == 1), None) for value in values]
    new_keys, new_values, new_features = {}, {}, []
    for k, feature in original:
        if k != 2:
            continue
        feature_fields = list(fields(feature))
        tags = [t for n, v in feature_fields if n == 2 for t in packed(v)]
        if len(tags) % 2:
            raise ValueError("Odd MVT tags")
        pairs = list(zip(tags[::2], tags[1::2]))
        if any(k >= len(keys) or v >= len(values) for k, v in pairs):
            raise ValueError("Out-of-bounds MVT tag")
        attributes = {keys[k]: strings[v] for k, v in pairs}
        if not keep_feature(name, attributes):
            continue
        retained_tags = bytearray()
        for old_key, old_value in pairs:
            key, value = keys[old_key], values[old_value]
            if key not in KEYS:
                continue
            new_keys.setdefault(key, len(new_keys)); new_values.setdefault(value, len(new_values))
            retained_tags += integer(new_keys[key]) + integer(new_values[value])
        # Preserve geometry commands exactly; strip source feature IDs and unused tags.
        body = b"".join(field(n, v) for n, v in feature_fields if n in (3, 4))
        if retained_tags:
            body = field(2, bytes(retained_tags)) + body
        new_features.append(field(2, body))
        stats[name] += 1
    if not new_features:
        return None
    return (field(1, name.encode()) + b"".join(new_features)
            + b"".join(field(3, key.encode()) for key in new_keys)
            + b"".join(field(4, value) for value in new_values)
            + b"".join(field(n, v) for n, v in original if n in (5, 15)))


def strip_tile(data, stats):
    layers = [strip_layer(v, stats) for k, v in fields(data) if k == 3]
    return b"".join(field(3, layer) for layer in layers if layer)


def build(source, destination, region):
    from pmtiles.reader import Reader, MmapSource, all_tiles
    from pmtiles.writer import Writer
    from pmtiles.tile import Compression, TileType, zxy_to_tileid
    stats = Counter()
    with source.open("rb") as infile, destination.open("wb") as outfile:
        get_bytes = MmapSource(infile)
        reader = Reader(get_bytes); header = reader.header()
        if header["tile_type"] != TileType.MVT or header["tile_compression"] != Compression.GZIP:
            raise ValueError("Expected gzip-compressed Protomaps vector tiles")
        writer = Writer(outfile)
        for (z, x, y), tile in all_tiles(get_bytes):
            stripped = strip_tile(gzip.decompress(tile), stats)
            # Keep empty tiles to retain the extract's coverage and zoom limits.
            writer.write_tile(zxy_to_tileid(z, x, y), gzip.compress(stripped, mtime=0))
        metadata = {"name": "Places Lite " + region, "version": VERSION,
                    "source": "Protomaps 20260925 (4.15.2)", "attribution": ATTRIBUTION,
                    "description": "Context map without buildings, POIs, addresses or source IDs.",
                    "vector_layers": [{"id": name, "fields": {key: "String" for key in sorted(KEYS)}} for name in sorted(stats)]}
        # PMTiles' writer timestamps its compressed directories and metadata. Fix
        # that timestamp too so the same inputs produce the same release bytes.
        compress = gzip.compress
        with patch("gzip.compress", lambda data, compresslevel=9, **kw: compress(data, compresslevel=compresslevel, mtime=0)):
            writer.finalize(header, metadata)
    size = destination.stat().st_size
    if region == "world" and size > 100_000_000:
        raise ValueError("World exceeds the 100 MB release ceiling")
    report = {"version": VERSION, "region": region, "bytes": size, "sourceBytes": source.stat().st_size,
              "sha256": hashlib.file_digest(destination.open("rb"), "sha256").hexdigest(),
              "features": dict(stats), "sourceSha256": hashlib.file_digest(source.open("rb"), "sha256").hexdigest()}
    destination.with_suffix(".json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path); parser.add_argument("destination", type=Path)
    parser.add_argument("--region", required=True, choices=["world", "netherlands", "greece"])
    args = parser.parse_args()
    build(args.source, args.destination, args.region)

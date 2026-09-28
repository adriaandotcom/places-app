#!/usr/bin/env python3
"""Generate measured country packs and real Amsterdam picker samples."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import unicodedata
import urllib.request

from build_lite import ATTRIBUTION, DETAIL_ZOOMS, build

PUBLIC_BASE = "https://places-app.b-cdn.net/maps"
AMSTERDAM_BOUNDS = [4.880, 52.367, 4.919, 52.387]
LOCK = Path(__file__).with_name("source-lock.json")


def download(url, destination):
    temporary = destination.with_suffix(destination.suffix + ".partial")
    with urllib.request.urlopen(url, timeout=120) as response, temporary.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            output.write(chunk)
    temporary.replace(destination)


def country_index(work):
    lock = json.loads(LOCK.read_text())
    work.mkdir(parents=True, exist_ok=True)
    path = work / "countries.geojson"
    if not path.exists():
        download(lock["boundaries"]["url"], path)
    if hashlib.sha256(path.read_bytes()).hexdigest() != lock["boundaries"]["sha256"]:
        raise ValueError("Country boundary checksum mismatch")
    countries = []
    for feature in json.loads(path.read_text())["features"]:
        properties = feature["properties"]
        name = properties["ADMIN"]
        ascii_name = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
        identifier = re.sub("[^a-z0-9]+", "-", ascii_name.lower()).strip("-")
        geometry = feature["geometry"]
        polygons = [geometry["coordinates"]] if geometry["type"] == "Polygon" else geometry["coordinates"]
        points = [point for polygon in polygons for ring in polygon for point in ring]
        bounds = [min(p[0] for p in points), min(p[1] for p in points), max(p[0] for p in points), max(p[1] for p in points)]
        code = properties.get("ISO_A2_EH", "")
        countries.append(dict(id=identifier, name=name, countryCode=code if re.fullmatch("[A-Z]{2}", code) else None,
                              bounds=bounds, variants=[], geometry=geometry))
    if len({c["id"] for c in countries}) != len(countries):
        raise ValueError("Duplicate country identifiers")
    return sorted(countries, key=lambda c: c["name"])


def validate_date(value):
    if not re.fullmatch(r"20\d{6}", value):
        raise ValueError("Source date must be YYYYMMDD from maps.protomaps.com/builds")
    datetime.strptime(value, "%Y%m%d")
    return value


def validate_version(value):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value) or len(value) > 64:
        raise ValueError("Invalid release version")
    return value


def simplified_ring(points, tolerance=0.003):
    """Keep islands/holes; simplify only their outlines for local suggestions."""
    def simplify(points):
        if len(points) <= 2: return points
        a, b = points[0], points[-1]
        dx, dy = b[0] - a[0], b[1] - a[1]
        length = dx * dx + dy * dy
        def distance(p):
            t = max(0, min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / length)) if length else 0
            return (p[0] - a[0] - t * dx) ** 2 + (p[1] - a[1] - t * dy) ** 2
        index = max(range(1, len(points) - 1), key=lambda i: distance(points[i]))
        if distance(points[index]) <= tolerance ** 2: return [a, b]
        return simplify(points[:index + 1])[:-1] + simplify(points[index:])
    reduced = simplify(points)
    if len(reduced) < 4: reduced = points
    return [[round(p[0], 5), round(p[1], 5)] for p in reduced]


def coverage(countries):
    result = {}
    for country in countries:
        geometry = country['geometry']
        polygons = [geometry['coordinates']] if geometry['type'] == 'Polygon' else geometry['coordinates']
        result[country['id']] = dict(type='MultiPolygon', coordinates=[
            [simplified_ring(ring) for ring in polygon] for polygon in polygons])
    return result


def build_region(country, work, pmtiles, source_date, version, preview=False):
    source_date = validate_date(source_date); version = validate_version(version)
    work.mkdir(parents=True, exist_ok=True)
    identifier = "amsterdam" if preview else country["id"]
    source = work / f"{identifier}-{source_date}-source.pmtiles"
    output = work / identifier / version
    output.mkdir(parents=True, exist_ok=True)
    command = [str(pmtiles), "extract", f"https://build.protomaps.com/{source_date}.pmtiles", str(source),
               "--minzoom=7", "--maxzoom=15", "--download-threads=4", "-q"]
    if preview:
        command.append("--bbox=" + ",".join(map(str, AMSTERDAM_BOUNDS)))
    else:
        outline = work / (identifier + ".geojson")
        outline.write_text(json.dumps(dict(type="FeatureCollection", features=[dict(type="Feature", properties={}, geometry=country["geometry"])])))
        command.append("--region=" + str(outline))
    if not source.exists():
        subprocess.run(command, check=True)
    # A failed extraction must never be mistaken for a completed cached input.
    subprocess.run([str(pmtiles), "verify", str(source)], check=True)
    updated = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    variants = []
    for detail, zoom in DETAIL_ZOOMS.items():
        destination = output / f"{detail}.pmtiles"
        build(source, destination, identifier, detail=detail, version=version, source_date=source_date)
        subprocess.run([str(pmtiles), "verify", str(destination)], check=True)
        report = json.loads(destination.with_suffix(".json").read_text())
        variants.append(dict(id=identifier, name="Amsterdam" if preview else country["name"], detail=detail,
                             version=version, bytes=report["bytes"], sha256=report["sha256"], minZoom=7, maxZoom=zoom,
                             url=f"{PUBLIC_BASE}/{identifier}/{version}/{detail}.pmtiles", updatedAt=updated,
                             sourceDate=source_date, bounds=AMSTERDAM_BOUNDS if preview else country["bounds"], attribution=ATTRIBUTION))
    entry = {k: v for k, v in country.items() if k != "geometry"} if not preview else dict(id="amsterdam", name="Amsterdam", bounds=AMSTERDAM_BOUNDS)
    entry["variants"] = variants
    (output / "entry.json").write_text(json.dumps(entry, indent=2) + "\n")
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--pmtiles", type=Path)
    parser.add_argument("--country", default="netherlands")
    parser.add_argument("--source-date", default="20260925")
    parser.add_argument("--version", default="20260928.1")
    parser.add_argument("--preview", action="store_true")
    parser.add_argument("--index-only", action="store_true")
    parser.add_argument("--coverage-only", action="store_true")
    args = parser.parse_args()
    if args.preview:
        print(build_region({}, args.work, args.pmtiles, args.source_date, args.version, preview=True))
        return
    countries = country_index(args.work / "source")
    if args.coverage_only:
        (args.work / 'country-coverage.json').write_text(json.dumps(coverage(countries), separators=(',', ':')) + '\n')
        return
    if args.index_only:
        index = dict(schemaVersion=1, countries=[{k: v for k, v in country.items() if k != "geometry"} for country in countries])
        (args.work / "country-index.json").write_text(json.dumps(index, separators=(",", ":")) + "\n")
        return
    country = next((country for country in countries if country["id"] == args.country), None)
    if country is None:
        raise ValueError("Unknown country; use a country ID from the index")
    print(build_region(country, args.work, args.pmtiles, args.source_date, args.version))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Publish verified immutable packs, then the catalog, using a storage-zone key."""
import argparse
from datetime import datetime, timezone
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import ssl
import math
from urllib.parse import urlsplit

from build_country import PUBLIC_BASE, validate_version, validate_date
from build_lite import DETAIL_ZOOMS

HOST = "storage.bunnycdn.com"
ZONE = "places-app"
MAX_METADATA = 2 * 1024 * 1024


def validate_entry(entry):
    identifier = entry.get("id", "")
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", identifier) or len(identifier) > 80:
        raise ValueError("Invalid country ID")
    bounds = entry.get("bounds", [])
    if (len(bounds) != 4 or not all(isinstance(v, (int, float)) and math.isfinite(v) for v in bounds)
            or not -180 <= bounds[0] < bounds[2] <= 180 or not -90 <= bounds[1] < bounds[3] <= 90):
        raise ValueError("Invalid country bounds")
    if not isinstance(entry.get("name"), str) or not 1 <= len(entry["name"]) <= 160:
        raise ValueError("Invalid country name")
    variants = entry.get("variants", [])
    if len(variants) != 3 or {p.get("detail") for p in variants} != set(DETAIL_ZOOMS):
        raise ValueError("A country must contain all three detail levels")
    for pack in variants:
        version = validate_version(pack["version"])
        expected = f"{PUBLIC_BASE}/{identifier}/{version}/{pack['detail']}.pmtiles"
        if pack["id"] != identifier or pack["name"] != entry["name"] or pack["url"] != expected:
            raise ValueError("Pack identity or URL mismatch")
        if not isinstance(pack["bytes"], int) or not 127 < pack["bytes"] <= 50_000_000_000:
            raise ValueError("Invalid measured pack size")
        if not re.fullmatch("[0-9a-f]{64}", pack["sha256"]):
            raise ValueError("Missing checksum")
        if (pack["minZoom"], pack["maxZoom"]) != (7, DETAIL_ZOOMS[pack["detail"]]):
            raise ValueError("Unexpected zoom coverage")
        if pack["bounds"] != bounds or datetime.fromisoformat(pack["updatedAt"].replace("Z", "+00:00")).tzinfo is None:
            raise ValueError("Missing coverage or update date")
        validate_date(pack["sourceDate"])
    if len({(p["version"], p["sourceDate"], p["updatedAt"]) for p in variants}) != 1:
        raise ValueError("All detail levels must come from the same build")
    return entry


def merge_catalog(index, previous, entries):
    if index.get("schemaVersion") != 1 or previous.get("schemaVersion", 1) != 1:
        raise ValueError("Unsupported catalog version")
    countries = {country["id"]: dict(country) for country in index["countries"]}
    if len(countries) != len(index["countries"]) or len({e["id"] for e in entries}) != len(entries):
        raise ValueError("Duplicate country entries")
    for country in previous.get("countries", []):
        if country["id"] in countries and country.get("variants"):
            validate_entry(country)
            countries[country["id"]]["variants"] = country["variants"]
    for entry in entries:
        validate_entry(entry)
        if entry["id"] not in countries:
            raise ValueError("Country is absent from the pinned index")
        if any(entry.get(k) != countries[entry["id"]].get(k) for k in ("name", "bounds", "countryCode")):
            raise ValueError("Country identity differs from the pinned index")
        old = countries[entry["id"]].get("variants", [])
        if old and min(p["sourceDate"] for p in entry["variants"]) < max(p["sourceDate"] for p in old):
            raise ValueError("Refusing to replace newer map data with an older source")
        countries[entry["id"]] = entry
    return dict(schemaVersion=1, generatedAt=datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
                countries=sorted(countries.values(), key=lambda c: c["name"]))


class Storage:
    def __init__(self):
        self.key = os.environ.get("BUNNY_STORAGE_KEY", "").strip()
        if not self.key:
            raise ValueError("Add the BUNNY_STORAGE_KEY repository Actions secret first")
        if any(ord(c) < 33 or ord(c) > 126 for c in self.key):
            # Avoid HTTP libraries including an invalid header value in errors.
            raise ValueError("BUNNY_STORAGE_KEY contains invalid characters; copy the storage access password again")

    def request(self, method, path, body=None, size=0, checksum=None, content_type="application/octet-stream"):
        if not path.startswith("/maps/") or ".." in path or "?" in path or "#" in path:
            raise ValueError("Uploads are restricted to /maps/")
        connection = http.client.HTTPSConnection(HOST, timeout=300, context=ssl.create_default_context())
        headers = {"AccessKey": self.key, "Content-Type": content_type}
        if method == "PUT":
            headers["Content-Length"] = str(size)
            if checksum: headers["Checksum"] = checksum.upper()
        try:
            connection.request(method, "/" + ZONE + path, body=body, headers=headers)
            response = connection.getresponse()
            status = response.status
            # Never return/log server bodies that might echo request information.
            payload = response.read(MAX_METADATA + 1) if method == "GET" else b""
            if len(payload) > MAX_METADATA:
                raise ValueError("Catalog exceeds its size limit")
            if status == 404 and method == "GET": return None
            if status not in (200, 201, 204): raise ValueError(f"Bunny Storage returned HTTP {status}")
            return payload
        finally:
            connection.close()

    def upload_packs(self, directory):
        entry = validate_entry(json.loads((directory / "entry.json").read_text()))
        for pack in entry["variants"]:
            path = directory / (pack["detail"] + ".pmtiles")
            with path.open("rb") as stream:
                if path.stat().st_size != pack["bytes"] or hashlib.file_digest(stream, "sha256").hexdigest() != pack["sha256"]:
                    raise ValueError("Generated pack no longer matches its measured metadata")
                stream.seek(0)
                self.request("PUT", urlsplit(pack["url"]).path, stream, pack["bytes"], pack["sha256"])
            print(f"Published {entry['id']} / {pack['detail']}: {pack['bytes']} bytes", flush=True)

    def publish_catalog(self, index, entries):
        existing = self.request("GET", "/maps/metadata.json")
        previous = json.loads(existing) if existing else {}
        catalog = merge_catalog(index, previous, entries)
        data = (json.dumps(catalog, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
        if len(data) > MAX_METADATA: raise ValueError("Catalog too large")
        # Country uploads have completed in their jobs before this final write.
        # The workflow serializes publications; existing files are never deleted.
        self.request("PUT", "/maps/metadata.json", data, len(data), hashlib.sha256(data).hexdigest(), "application/json")
        readback = self.request("GET", "/maps/metadata.json")
        if readback != data: raise ValueError("Published catalog readback failed")
        print(f"Catalog published and verified: {len(catalog['countries'])} countries and territories", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    upload = commands.add_parser("upload"); upload.add_argument("directory", type=Path)
    catalog = commands.add_parser("catalog"); catalog.add_argument("--index", type=Path, required=True); catalog.add_argument("--entries", type=Path, required=True)
    args = parser.parse_args()
    storage = Storage()
    if args.command == "upload": storage.upload_packs(args.directory)
    else: storage.publish_catalog(json.loads(args.index.read_text()), [json.loads(path.read_text()) for path in sorted(args.entries.rglob("entry.json"))])

# Orange-point route experiment

In **Map → Nerd mode → Location collectors**, import the Places Valhalla ZIP,
choose Walking, Bicycle or Driving, then enable **Valhalla routes**. The setting
and profile persist across screen switches and launches. The existing date/range
picker selects the evidence. Recording is unchanged and remains independently
controlled. This experiment is off by default and does not feed timeline inference.

Only `TraccarPoint` records (orange dots) enter matching. Places observations,
photos, saved-place coordinates, motion classifications, Watch and Mac data are
excluded. Original records/dots remain unchanged and available. Solid orange
lines are estimated matches; unmatched continuous sections remain dashed.
Intervals without enough evidence are not joined into a matched route.

The preparer sorts/deduplicates evidence, breaks at poor/missing accuracy over
100 m, duplicate times, implausible jumps or gaps over five minutes, and submits
at most 250 points per native request. Long sections share one boundary point.
Selections over 10,000 points ask for a shorter period. A section with unmatched
points, discontinuities or excessive offsets is rejected as a whole. This is a
conservative initial comparison, not proof that a road was travelled. Dense
traces work better than our battery-oriented sparse recording.

Distance sums matched edge lengths, including partial edges. Observed span sums
first-to-last recorded timestamps of accepted sections, including stops; it is
not moving time or Valhalla's predicted travel time. Gaps and rejected sections
are excluded from these statistics. The UI shows matched-point coverage.

## Local engine

- Rallista Valhalla Mobile **0.6.4**, binary SHA-256
  `c12b796de073e89f6b0be02cbfabf845a324166467609268d747c094d27ddb47`.
- Valhalla **3.9.1**, source `bafb69902220615a48307d5c790fb6c943802ba4`.
- The small Places Objective-C++ bridge calls the native actor directly with
  **no HTTP client**. The upstream Swift/Objective-C network wrapper is unused.
- Only bundled configuration is accepted. It has no remote tile/elevation URL,
  HTTP service, StatsD or other telemetry configuration. Native logging is
  disabled before graph access; native exception strings never reach logs/UI.
- The upstream mobile binary runs actions on a dedicated 16 MB stack. Native
  work is serialized on a Swift actor outside the main thread, bounded/chunked,
  and cancellation is checked between actions. Backgrounding, screen changes,
  disabling the layer and deletion cancel pending results and close the reader.
  An in-progress synchronous native action finishes before close.
- Graph cache is capped at 64 MB; at most 40 successful sections are retained
  in memory. Raw evidence and derived results have no shared persistence table.
  Reset/restore clears result caches; full reset also removes routing data.

## Netherlands starter data

Public Geofabrik extract dated **2026-10-08**:
`https://download.geofabrik.de/europe/netherlands-261008.osm.pbf`.
Source bytes: **1,405,342,443**; SHA-256:
`28fc1f4b2c41360fa940c3e0b947b5b37957a19d66401f724090021b64a7bd3c`.

Built locally with Valhalla 3.9.1, two workers, no container network. Includes
walking/cycling/driving graph connectivity and restrictions. Administrative,
timezone, elevation, timetable and traffic enrichment are not supplied. The
experiment uses recorded elapsed time and no routing ETA, so these omissions
do not change the observed-time calculation.

- Installed extract: **943,237,120 bytes**.
- ZIP: **347,647,021 bytes**.
- ZIP SHA-256: `02d0eee0d1bb30704c70701711178638b907ea030ed8f8eee1550ce5730bdf84`.
- Graph SHA-256: `d0297503e005b7b191a52d2d787d8d975f12c9e1981cd27481c0890f3d80d799`.

The ZIP lives in ignored `build/artifacts/Places-Valhalla-Netherlands-2026.10.08.zip`.
Transfer it through AirDrop/Files and import explicitly; Places does not download
it automatically. Keep the ZIP plus roughly 1 GB free for installation. The ZIP
contains `pack.json`, `tiles.tar` and a human-readable `README.txt`. Import streams
the graph, verifies CRC, size and SHA-256, and accepts only an exact entry in the
bundled catalog. No imported configuration or arbitrary native graph is accepted.
Installation uses staging/rollback recovery. Routing data is protected after
first unlock, excluded from device backups and removable in the same screen.
Data is © OpenStreetMap contributors, ODbL 1.0; attribution is bundled in the app.

To build a new pack from public OSM data:

```sh
PLACES_ROUTING_IMAGE=ghcr.io/valhalla/valhalla@sha256:4fd114eb1d26b8fc2f43bcb3df234c1b63a0bf13c277405e5943d5361dc575de
docker pull "$PLACES_ROUTING_IMAGE"
# Put the dated, verified OSM extract in /tmp/places-routing-build first.
docker run --rm --network none -v /tmp/places-routing-build:/data "$PLACES_ROUTING_IMAGE" valhalla_build_config --mjolnir-tile-dir /data/tiles --mjolnir-tile-extract /data/tiles.tar --mjolnir-concurrency 2 > /tmp/places-routing-build/build.json
docker run --rm --network none -v /tmp/places-routing-build:/data "$PLACES_ROUTING_IMAGE" valhalla_build_tiles -c /data/build.json -j 2 /data/netherlands-261008.osm.pbf
docker run --rm --network none -v /tmp/places-routing-build:/data "$PLACES_ROUTING_IMAGE" valhalla_build_extract -c /data/build.json
python3 scripts/package_routing_pack.py --graph /tmp/places-routing-build/tiles.tar --output build/artifacts/Places-Valhalla-Netherlands-NEW.zip --name Netherlands --version NEW --bounds 50.75 3.2 53.7 7.24 --source https://download.geofabrik.de/europe/netherlands-261008.osm.pbf --source-sha256 28fc1f4b2c41360fa940c3e0b947b5b37957a19d66401f724090021b64a7bd3c --catalog packages/PlacesRouting/Sources/PlacesRouting/Resources/packs.json
```

Use the pinned image digest for all commands when rebuilding. Review the new
catalog, sizes, licenses and native compatibility before publishing a new app
that accepts it. Different graph builds may have different checksums; older
app builds intentionally reject packs absent from their catalog.

## Validation and limitations

Core tests cover request timestamps/accuracy, source isolation, gaps, jumps,
polyline6, unmatched/disconnected responses and distance/time semantics. Native
integration uses the public SDK's small Andorra fixture; that fixture is only
in the test bundle. Import tests reject unknown metadata, modified graph bytes
and traversal entries. UI checks exercise both existing map providers and
preservation of the date/profile without enabling location collection. An unsigned
Release iPhone build also compiled and linked the arm64 native engine; this is
build validation, not physical-device background or battery validation.

A separate native iOS Simulator smoke test with public synthetic Amsterdam
points matched both points for pedestrian/bicycle/auto against the new Netherlands
graph. Result lengths were 820/864/870 m; processing took 48/10/4 ms with one actor
(later actions benefited from warm caches). This is a small simulator feasibility
sample, not a device performance or battery guarantee. Test your own recorded
walks/rides, pauses, background cancellation and memory/energy behavior on-device.

A local acceptance run also imported the complete Netherlands ZIP, matched the
public synthetic trace using all three profiles and deleted the installed pack
successfully (5.0 s for that test on this simulator). The temporary acceptance
test was removed after the run; shipping tests use the small public fixture.

On 2026-10-10, OSV returned no advisory matches for the existing pinned GRDB,
ZIPFoundation, MapLibre, Kotlin and coroutines versions. Protobuf C++ 4.25.1 is
newer than the fixed 4.25.0 range in GHSA-h5g9-ghrj-76p5; later Python/Java/PHP
advisories do not describe the compiled C++ runtime. Valhalla embeds RapidJSON
commit `083f359f5c36198accc2b9360ce1e32a333231d9` (2023), which includes the
2018 exponent-underflow fix referenced by CVE-2024-38517. CVE-2024-39684 lists
release 1.1.0; the later upstream discussion concerns `unsigned` narrower than
32 bits, whereas the Apple builds use 32-bit unsigned and app-generated bounded
finite-number JSON. These checks are not a guarantee that dependencies are free
of vulnerabilities. The 0.6.4 changelog was reviewed for the 3.9.1 upgrade and
the prior mobile stack-safety fix; no published applicable upgrade was identified.

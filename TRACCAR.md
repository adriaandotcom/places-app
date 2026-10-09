# Offline Traccar comparison

The iPhone can run the Places collector and an opt-in Traccar comparison collector together.
Enable **Settings → Location collectors → Traccar comparison**, with Always location access.
The normal recording switch pauses both. Traccar is off by default. Existing Places tracking
and timeline inference remain the primary path.

In Map, enable Nerd mode using the eye icon, then open the adjacent collectors control.
**Places points** and **Traccar points** are independent persisted layers. Green and orange
points and dashed lines show each collector's measurements in time order. Lines do not
imply coverage between fixes. Tap a point for its time, coordinates, accuracy and source.
The existing day/range picker applies to both; all-history includes older Traccar-only data.
Apple Maps still requires map consent. The on-device provider renders without map requests.

## Actual SDK fork

- Upstream: https://github.com/traccar/traccar-client-sdk
- Base: `9037a8866c690ea20934b1da12868e1cf221a2bc`
- Fork: https://github.com/adriaandotcom/traccar-client-sdk
- Pinned SwiftPM release: `1.1.1-places.1`, with an XCFramework checksum.
- Apache 2.0; notices are bundled in the app's licenses screen.

This is the Kotlin Multiplatform SDK's actual iOS engine, not a Swift reimplementation.
The fork keeps its native location source, location filter, Core Motion detector, stationary
region detector and signal engine. It replaces the HTTP uploader, server/device configuration,
network monitor, SQLDelight retry queue, log database and automatic initializer. Only Kotlin
standard library and coroutines are runtime dependencies; no HTTP library is compiled.
Upstream's Android/Flutter/React Native sources remain reference material in the fork and
are not part of this iOS artifact.

`LocationSource → LocationFilter → TrackerEngine → OfflineOutput → Places SQLite`

Defaults are 100 m desired accuracy, 75 m distance / 300 s time acceptance, 60 s stationary
motion timeout and a 100 m stationary geofence. The time acceptance rule is a filter on
incoming fixes, not a GPS polling timer. Heartbeat is disabled. Platform auto-pause and
significant-change recovery remain enabled while stationary; restoring a stationary engine
does not start standard GPS. No permission prompt is issued by the SDK itself.

The host creates it only after protected storage is available. Output acknowledges success
only after SQLite commits. Write failure stops the collector and appears in its settings.
Reset/restore closes the engine and drains pending host writes before modifying history.
Both collectors ignore each other's region events and preserve each other's region slots.

## Persistence and privacy

Migration `v12-traccar-offline-history` adds `traccarPoints`, separate from observations,
route points, timeline, photo evidence and companion imports. No Traccar record is passed to
inference or companion CloudKit. There is no server URL, device identifier, upload or retry queue.
The records inherit the database's after-first-unlock protection and backup exclusion.
History is never pruned automatically. Full JSON exports and portable ZIP backups include
it, with date filtering for JSON exports. Delete-all removes it. Backup format 2 restores both
collectors; format 1 backups without Traccar remain supported. Restore leaves recording off.
Redacted diagnostics do not include these points.

## Validation

Automated checks cover durable/idempotent storage, half-open date ranges, timeline isolation,
invalid-input rejection, ZIP round trips, legacy backups, deletion, the Kotlin/Swift persistence
callback, failure-to-save handling, stop/wake signals, geofence isolation and both map providers.
The SDK includes `scripts/check_offline.py` to reject network plumbing in compiled source sets.

On 2026-10-09, OSV queries returned no published advisories for the pinned Kotlin 2.4.20,
coroutines 1.11.0, GRDB 7.11.1, ZIPFoundation 0.9.20 and MapLibre distribution 6.31.0 versions.
This check does not establish the absence of vulnerabilities.

Physical-device validation is still required: compare an overnight stationary interval, a
walk/bike journey, leaving a geofence after suspension, relaunch after first unlock, permission
revocation and recording pause. Verify the saved points and iOS battery report. Running two
collectors may increase energy use; simulator tests cannot establish a battery improvement.
Both collectors use the same iPhone and system location services. Their saved outputs are
independent, but running them together does not measure either collector's energy use in
isolation. Keep the comparison disabled when measuring the existing Places baseline.

# Places

A private location history for iPhone, built with SwiftUI. Observations, inference,
places, corrections, and search live on the device. There is no account or backend.
Normal first launch starts empty.

This public repository is **source-available under PolyForm Noncommercial 1.0.0**,
not OSI open source. See [LICENSE](LICENSE) and [NOTICE](NOTICE). GRDB and the
bundled Bricolage Grotesque fonts retain their own licenses.

## Run

- iOS 26 or later; Xcode 26.6 or later with Swift 6 support.
- Open `apps/ios/Places.xcodeproj`, select Places and an iPhone simulator, and run.
- For a physical iPhone, configure your own signing team locally. Connected Wi-Fi
  uses Apple's Access WiFi Information entitlement and requires precise location
  authorization; availability is controlled by iOS.
- The project is checked in. With XcodeGen installed, `make generate` recreates it
  from `apps/ios/project.yml`.
- `make test` runs the core tests and privacy checks. `make build` compiles the app
  for Simulator. `make website` serves the static site at `http://127.0.0.1:4173`.

GRDB is pinned to 7.11.1. Package downloads happen during development/builds;
the app does not download dependencies or executable code at runtime.

The opt-in [Valhalla route experiment](VALHALLA.md) matches only the independent
orange Traccar points using an explicitly imported local routing pack. It does
not change recording or timeline inference. See the measured pack sizes and
limitations before enabling it.

## Repository

| Path | Responsibility |
| --- | --- |
| `apps/ios` | SwiftUI, Apple sensor adapters, permissions, protected storage |
| `packages/PlacesCore` | Models, SQLite migrations, evidence, inference, local search |
| `apps/website` | Static landing page with bundled fonts and images |
| `scripts` | Privacy checks, CI smoke tests, simulator selection, icon generation |

The original design exports and product specification remain outside this repository.
The canonical contribution and privacy rules are in [AGENTS.md](AGENTS.md).

## Implemented foundation

- Skippable onboarding; actual authorization status and recovery through Settings.
- Adaptive location recording with Visits, significant changes, monitored regions,
  optional motion, and opportunistic connected Wi-Fi observations.
- Timeline, dates, place editing, Wi-Fi classifications, local search, stay and
  transport corrections, unknown intervals, and local diagnostics.
- Apple Maps behind persisted explicit consent; disabling it removes active maps.
- Local JSON history export, redacted diagnostic export, and confirmed deletion.
- SQLite transactions and versioned migrations; raw evidence is preserved separately
  from inference and durable user corrections. There is no automatic retention cutoff.

Automatic stops require at least three minutes of fresh, reasonably accurate
evidence with little movement, including at saved places. Nearby place membership
alone never confirms a visit. An explicit **Count walks as visits** preference on
each place also permits a three-minute walk within its area; cycling remains travel.
Walking visits retain their measured path, with recording gaps left unconnected.
**Just passing through** converts a visit back to travel and supports Undo. Policy
upgrades rebuild derived history while retaining raw observations and manual edits.
Leaving an established stop requires two fresh displaced fixes at least 15 seconds
apart, or a system departure event; an isolated speed spike cannot start a journey.
Brief same-place returns are grouped only when recorded fixes support staying put,
with their original intervals retained for inspection and splitting. One-second
uncorrected edges of a transport correction join the corrected journey visually;
the correction's exact interval remains unchanged.

A fresh connection to a learned fixed Wi-Fi access point pauses detailed GPS
immediately, independently of the three-minute visit confirmation. One subsequent
connection read can confirm dwell; it does not request a GPS fix. Indoor movement,
foregrounding, and charging do not override this pause. Disconnection, unavailable
Wi-Fi information, or a contradictory departure resumes bounded location recovery.
Unknown access points and portable networks cannot suppress route recording.
Charging retains adaptive accuracy, automatic pausing, and recovery deadlines.

History uses protection compatible with recording after the first unlock, including
database sidecars, and is excluded from automatic backups. Full exports contain
sensitive history: the user chooses where to save them. Apple system location
services follow the device's privacy settings. No analytics, remote assets, hosted
AI, third-party runtime services, or background cloud sync are included.

## Validation and remaining acceptance work

Run `python3 scripts/validate_local.py --simulator <QA-simulator-UUID>` locally
for core and companion tests, the Mac build, and app/UI tests. CI checks privacy
and builds/releases the apps. Debug-only UI fixtures are synthetic and in memory;
`--ui-testing --ui-fixture` is available only in Debug builds.

**This is a working foundation, not yet a device-validated tracker.** Before claiming
reliable history, test a real outing and confirm:

1. Persistent, editable stays and journeys after ordinary backgrounding and relaunch.
2. Locked-device recording after first unlock, and safe deferral before first unlock.
3. Foreground-only, Always, approximate, denied, and revoked permissions; every
   skipped permission leaves useful manual functionality.
4. Honest gaps following force-quit, missing signals, and unsupported relaunches.
   iOS controls background execution; force-quit can prevent automatic recovery.
5. Actual network activity with Maps off, enabled, and disabled again. Source scans
   and URLSession interception alone do not cover MapKit or system processes.
6. Stationary versus moving energy use, battery-saving recovery, and Wi-Fi behavior
   on a signed physical iPhone. Local policy counters are not battery measurements.
7. VoiceOver, large text, dark appearance, and reduced motion on device.

Calendar/Health enrichment, purchases, opt-in iCloud, Watch/Mac companions, advanced
editing, trips, and local natural-language search are later milestones. They have no
working controls or permission requests in this build. Website hosting is deferred.

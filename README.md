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

History uses protection compatible with recording after the first unlock, including
database sidecars, and is excluded from automatic backups. Full exports contain
sensitive history: the user chooses where to save them. Apple system location
services follow the device's privacy settings. No analytics, remote assets, hosted
AI, third-party runtime services, or background cloud sync are included.

## Validation and remaining acceptance work

CI runs critical core tests, static privacy/resource checks, simulator compilation,
and UI tests for skipped permissions, local editing/search, map consent, and
accessibility navigation. Debug-only UI fixtures are synthetic and in memory;
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

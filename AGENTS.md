# Places

## Product and privacy

- Native Swift/SwiftUI for iOS 26+. Local storage and processing by default. No account or backend is required.
- No analytics, telemetry, advertising SDKs, hosted AI, third-party services, CDNs, remote fonts/images, or downloaded executable code. These restrictions apply to the website too.
- The only network exceptions are explicitly enabled Apple Maps/place lookup and iCloud sync, and StoreKit purchases when implemented. Strava is excluded. Build-time dependency downloads are not runtime services.
- Gate every Maps view, preview, snapshot, search, and geocoder behind persisted consent before constructing it. Disabling consent must tear down active map UI. No implicit cloud storage or synchronization.
- Bundle and license assets. Use SF Symbols in native UI. Website resources must come from its own origin; external links must never prefetch.
- Request only permissions used by implemented features. Every onboarding permission is skippable. Reflect actual system authorization and offer recovery through Settings. Never imitate system permission alerts.
- Do not advertise or expose working controls for deferred features (Calendar, Health, iCloud, purchases, Watch, Mac, local AI).

## Evidence and tracking

- Sensor adapters produce raw observations. Tracking policy decides sensor activity. Deterministic inference produces history. UI must not infer locations.
- Raw evidence and inferred stays/journeys/gaps are separate. User corrections are durable overrides and outrank inference. Preserve reasons and stable IDs.
- Unknown intervals remain unknown. Never invent routes, times, device connections, or a reason such as "phone was off" without evidence.
- Event-driven adaptive tracking only: no hourly GPS timers, continuous maximum accuracy, or Wi-Fi polling. Stop standard location updates when stationary; keep supported low-power recovery mechanisms.
- Read only the connected iOS Wi-Fi network through supported APIs and entitlements. Do not scan unconnected networks or use private APIs.
- One place may have many SSIDs/BSSIDs; the same SSID may occur at many places. Portable and ignored networks never establish fixed-place evidence. Preserve explicit classifications.
- Keep raw evidence until user deletion; no automatic pruning. Version tracking policy and migrations. Physical-device lifecycle and energy validation is required before claiming reliable background tracking.

## Data safety

- Use platform data protection, including SQLite WAL/SHM files, compatible with background writes after first unlock. Do not access the database while protected data is unavailable.
- Exclude sensitive history from automatic device backup by default. No implicit iCloud container.
- Ordinary logs must not contain coordinates, place names, SSIDs/BSSIDs, Calendar/Health data, or secrets. Diagnostics are local, user-initiated, and redacted. Clearly distinguish full history export from diagnostics.
- Never commit personal histories, real Wi-Fi identifiers, credentials, signing configuration, device databases, reference exports, or unlicensed images. Fixtures are synthetic.
- Any future production debugging commands must minimize and redact personal information.

## Engineering and publication

- Swift 6 concurrency, SwiftUI, shared PlacesCore package, SQLite/GRDB. Keep Apple sensor/UI adapters outside the shared core. Prefer small explicit interfaces over speculative abstractions.
- Preserve the supplied design's cream surfaces, typography, colored cards, and timeline hierarchy while respecting safe areas, Dynamic Type, VoiceOver, dark appearance, and reduced motion.
- Maintain `PlaceIconMatcher.swift` with reproducible name/category matches (including common local-language words) when new ones are found. Keep Unicode word boundaries, prefer specific phrases and category evidence, preserve manual icon choices, and add regression examples. Reuse one canonical pictogram per concept; keep synonyms searchable instead of adding outlined/circled duplicates.
- Use PolyForm Noncommercial 1.0.0 for original code. Call the public project source-available, not OSI open source. Preserve dependency/asset license notices.
- Pin dependencies. For larger features, check published vulnerable version ranges and read release/changelog notes before necessary upgrades.
- Test critical inference, migration, recovery, data deletion, consent gating, and durable corrections. Add inexpensive smoke tests for workflow scripts. Never replace device validation with simulator claims.
- XcodeGen's `apps/ios/project.yml` is the project source of truth; commit the generated project and resolved dependency versions. Signing settings stay local.
- This personal project publishes validated changes directly to `main`; no PR or issue is required. Keep the repository public. Stage explicit paths and verify the remote commit and CI after pushing.

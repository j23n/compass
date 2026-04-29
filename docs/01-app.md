# Project: Compass — Self-hosted fitness watch companion app for iOS

You are scaffolding a complete iOS 18+ SwiftUI app called "Compass" that syncs
activity, sleep, and daily wellness data from a Garmin Instinct Solar watch
over BLE — without relying on Garmin Connect or Garmin's cloud. The app parses
FIT files locally and presents the data in an Apple Fitness–inspired UI.

The app will be distributed via TestFlight, so all UI copy and Info.plist
strings must avoid Garmin trademarks. Refer to the watch as "your fitness
watch" or "compatible device" in user-facing strings. Internal code, comments,
and README can reference Garmin and the Instinct Solar specifically.

This is an MVP scaffold. You should produce a complete, buildable Xcode
project with stubs and mocked data where real implementations are out of scope
for a single pass. The goal is a runnable app where the UI works against
mocked data and the architecture cleanly accepts real data flowing from BLE
+ FIT parsing as those pieces get filled in.

## Tech stack and constraints

- iOS 18.0+ minimum deployment target
- SwiftUI, SwiftData for persistence
- Swift Charts for trend visualizations
- Core Bluetooth for BLE
- AccessorySetupKit for the pairing flow
- MapLibre Native iOS SDK for activity maps with OpenStreetMap tiles
- No Apple HealthKit integration in MVP, but the data schema must be
  HealthKit-compatible: each persisted metric should map cleanly to an
  HKQuantityType or HKCategoryType so a HealthKit bridge can be added later
  without schema migration
- No third-party dependencies except MapLibre Native (via SwiftPM)
- Use Swift 6 strict concurrency

## Visual design direction

Apple Fitness-inspired:
- Colorful rings as the primary glanceable element on the home/today view
  (Activity ring, Sleep ring, Body Battery ring, HRV/Stress ring)
- Big numbers, generous whitespace
- SF Pro typography, Dynamic Type respected
- Use system colors with a vibrant accent palette per metric:
  red (heart rate), green (activity), purple (sleep), blue (body battery),
  orange (stress)
- Light and dark mode both supported

## App structure

Three top-level tabs:

### 1. Today
A vertically scrolling dashboard showing today's data:
- Hero section: four rings (activity, sleep, body battery, stress) at the top
- Resting heart rate card with sparkline of last 24h
- Last night's sleep card with stage breakdown bar
- Today's activities list (each row tappable → activity detail)
- Body Battery curve over the last 24h
- Stress curve over the last 24h

### 2. Activity (detail view, navigated to from Today or Health)
- Map at top showing the GPS track (MapLibre, OSM tiles)
- Hero stats below map: distance, time, pace, avg HR
- Tabs/sections for: splits, HR zones, elevation profile, lap breakdown
- All charts use Swift Charts

### 3. Health (trends)
- Time range picker (week, month, 3 months, year)
- Stacked sections, each scrollable:
  - Resting HR over time
  - HRV over time
  - Sleep duration + stage breakdown over time
  - Body Battery min/max envelope over time
  - Stress average over time
  - Steps and activity minutes
- Each chart tappable → fullscreen detail

Plus a Settings sheet accessible from the Today tab toolbar:
- Connected device status
- Pair new device (triggers AccessorySetupKit flow)
- Manual sync button
- Last sync time
- About / acknowledgements

## Module architecture

Create the project as a single iOS app target plus three local Swift packages:

```
Compass/
├── Compass/                      # iOS app target (UI)
│   ├── App/
│   ├── Views/
│   │   ├── Today/
│   │   ├── Activity/
│   │   ├── Health/
│   │   └── Settings/
│   ├── ViewModels/
│   ├── Components/               # Reusable: Ring, MetricCard, etc.
│   └── Resources/
├── Packages/
│   ├── CompassData/              # SwiftData models + repositories
│   ├── CompassFIT/               # FIT parsing + HarryOnline overlay
│   └── CompassBLE/               # Garmin BLE protocol port
└── Compass.xcodeproj
```

Each package has its own Package.swift with appropriate dependencies and is
imported into the main app target.

## CompassData package (SwiftData layer)

Define `@Model` classes designed for HealthKit migration. Each model has a
property mapping comment showing the eventual HK type:

- `Activity` — id, startDate, endDate, sport (enum), distance, duration,
  totalCalories, avgHeartRate, maxHeartRate, totalAscent, totalDescent,
  trackPoints (relationship). // Maps to HKWorkout
- `TrackPoint` — timestamp, latitude, longitude, altitude, heartRate,
  cadence, speed, temperature, parentActivity (relationship).
  // Maps to HKWorkoutRoute samples + HKQuantitySamples
- `SleepSession` — id, startDate, endDate, score, stages (relationship).
  // Maps to HKCategoryTypeIdentifier.sleepAnalysis
- `SleepStage` — startDate, endDate, stage (enum: awake/light/deep/rem),
  parentSession (relationship). // Maps to HKCategorySample
- `HeartRateSample` — timestamp, bpm, context (enum: resting/active/sleep)
  // Maps to HKQuantityType.heartRate
- `HRVSample` — timestamp, rmssd, context (enum). // Maps to
  HKQuantityType.heartRateVariabilitySDNN (note: rmssd vs sdnn distinction
  to handle in bridge)
- `StressSample` — timestamp, stressScore (0–100, Garmin's scale).
  // Custom; no direct HK equivalent, store as-is
- `BodyBatterySample` — timestamp, level (0–100).
  // Custom; no direct HK equivalent
- `RespirationSample` — timestamp, breathsPerMinute.
  // Maps to HKQuantityType.respiratoryRate
- `StepCount` — date (day), steps, intensityMinutes, calories.
  // Maps to daily HKQuantitySample.stepCount
- `ConnectedDevice` — id, name, model, lastSyncedAt, fitFileCursor

Repositories (one per model family) expose query methods:
`activitiesIn(dateRange:)`, `latestSleep()`, `bodyBatterySamples(in:)`, etc.
Repositories return AsyncSequence where appropriate so the UI can react to
new data flowing in from sync.

Include a `MockDataProvider` that seeds a SwiftData container with realistic
fake data spanning the last 90 days, so the UI works without any real
device. The mock data should be deterministic (seeded random) so screenshots
and previews are stable.

## CompassFIT package (FIT parsing)

Use roznet/FitFileParser (Swift, MIT) as the foundation. Add it via SwiftPM.

On top of it, implement a `FieldNameOverlay` system:
- Loads a JSON file `harry_overlay.json` bundled in the package
- The JSON maps (message_number, field_number) tuples to human-readable
  names with type hints, e.g.:

```json
  {
    "messages": {
      "140": {
        "name": "monitoring_hr",
        "fields": {
          "0": {"name": "timestamp", "type": "timestamp"},
          "3": {"name": "heart_rate", "type": "uint8", "unit": "bpm"}
        }
      },
      "273": {
        "name": "sleep_data_info",
        "fields": { ... }
      },
      "346": {
        "name": "body_battery",
        "fields": { ... }
      }
    }
  }
```

- Seed the JSON with placeholders for these messages (real values will be
  added later from HarryOnline's spreadsheet — leave a TODO comment with the
  URL):
  - 140 monitoring_hr
  - 211 monitoring_info
  - 273 sleep_data_info
  - 275 sleep_stage
  - 346 body_battery
  - 369 training_readiness
  - 382 sleep_restless_moments
  - 412 nap

- Provide a `FieldNameOverlay.applyTo(parsedMessage:)` function that
  enriches the raw parsed output with names from the JSON

Define typed parser entry points that return CompassData model instances:
- `ActivityFITParser.parse(url:) -> Activity` — parses /GARMIN/Activity/*.fit
- `MonitoringFITParser.parse(url:) -> [HeartRateSample, StressSample,
  StepCount, BodyBatterySample, RespirationSample]` —
  parses /GARMIN/Monitor/*.fit
- `SleepFITParser.parse(url:) -> SleepSession` — parses /GARMIN/Sleep/*.fit
- `MetricsFITParser.parse(url:) -> [HRVSample]` — parses /GARMIN/Metrics/*.fit

Each parser:
1. Uses FitFileParser.generic mode to get all messages
2. Applies the overlay to enrich field names
3. Maps known messages to model objects
4. Logs (via os.Logger) any unknown messages encountered for future overlay
   contributions
5. Returns parsed objects via async functions

Include unit tests with sample FIT files. Since we don't have real Instinct
Solar files yet, generate synthetic FIT files in the test target using the
official Garmin FIT SDK encoder (also available via SwiftPM as
garmin/fit-objective-c-sdk — add it as a test-only dependency).

## CompassBLE package (Garmin BLE protocol port)

This is the deepest part of the project and the most stubbed. The module
should have the right shape but implementation is intentionally incomplete.

Service UUID: `6A4E2800-667B-11E3-949A-0800200C9A66` (Garmin ML)

Core types:
- `GarminDeviceManager` — main API surface
  - `discover() -> AsyncStream<DiscoveredDevice>`
  - `pair(_ device:) async throws -> ConnectedDevice` (uses
    AccessorySetupKit when possible)
  - `connect(_ device:) async throws`
  - `disconnect()`
  - `pullActivityFiles() async throws -> [URL]` (returns local URLs of
    pulled FIT files)
  - `pullMonitoringFiles() async throws -> [URL]`
  - `pullSleepFiles() async throws -> [URL]`
  - `uploadCourse(_ url:) async throws` (FIT or GPX file)

- `MultiLinkTransport` — stub class implementing the chunking, encoding,
  and handle management for the Multi-Link reliable protocol. Document the
  protocol structure in code comments based on Gadgetbridge's
  documentation (cite GitLab paths in comments).

- `GFDIClient` — stub for the Garmin Fit Data Interface service. Methods:
  `requestFileList()`, `downloadFile(id:)`, `uploadFile(data:type:)`.

- `AuthenticationManager` — stub for the OAuth-fake-credentials handshake
  Gadgetbridge uses. Comment heavily about what this does and why.

For each stub, write the full method signature, mark the body with
`// TODO: Port from Gadgetbridge`, throw a `NotImplementedError`, and
include a comment block referencing the relevant Gadgetbridge file path:

```swift
// Port reference: Gadgetbridge/app/src/main/java/nodomain/freeyourgadget/
// gadgetbridge/service/devices/garmin/GarminSupport.java
// Specifically the GFDI message handlers
```

Provide a `MockGarminDevice` implementation of the same protocol that
returns canned FIT files from the test bundle. The app should use this in
DEBUG builds when no real device is paired, so the full sync flow can be
exercised end-to-end without hardware.

## App-level wiring

- `CompassApp.swift` — sets up SwiftData container, dependency container,
  decides whether to use real GarminDeviceManager or MockGarminDevice based
  on a launch argument or DEBUG build flag, seeds mock data on first run

- `SyncCoordinator` — orchestrates: BLE pull → FIT parse → SwiftData write.
  Exposes a published progress state for the Settings UI.

- Use a simple DI container (manual, no third-party) — protocol-typed
  dependencies passed via initializer.

## UI specifics

Today view:
- The four rings should be a custom `RingsView` component, animated on appear
- Each ring is a `RingView` with configurable progress (0–1), color, icon,
  label, and value text
- Below rings: stack of cards using a shared `MetricCard` component
- Pull-to-refresh triggers SyncCoordinator.sync()
- If no device is connected, show an empty state with a "Pair a device"
  CTA that opens Settings

Activity detail:
- MapLibre map view at top, ~40% screen height
- Use OSM standard tiles for now: `https://tile.openstreetmap.org/{z}/{x}/{y}.png`
  (note: OSM tile policy requires identifying user agent; set it correctly
  and add a TODO to switch to a paid tile provider before significant usage)
- Track polyline drawn from TrackPoints, color-graded by speed or HR
  (toggle in toolbar)
- Stats grid below
- Elevation profile chart using Swift Charts AreaMark
- HR-over-time chart, swipeable to switch metrics

Health view:
- Each metric section has its own SwiftUI view, all conforming to a
  `TrendSection` protocol with `dateRange`, `data`, and `chartView`
- Tap-and-hold on chart shows callout with exact value at that timestamp
  (Swift Charts ChartProxy)

Settings:
- Use AccessorySetupKit (`ASAccessorySession`) for pairing flow
- Show pairing prompt with a custom `ASPickerDisplayItem` configured for the
  Garmin BLE service UUID

## Required Info.plist entries

- `NSBluetoothAlwaysUsageDescription`: "Compass connects to your fitness
  watch to sync activity and health data."
- `UIBackgroundModes`: bluetooth-central
- AccessorySetupKit entitlement key

## What to deliver

1. Complete Xcode project (Compass.xcodeproj) opened to a buildable state
2. All three packages with full `Package.swift` files
3. SwiftData models with HealthKit-mapping comments
4. CompassFIT package wrapping FitFileParser with the overlay system and
   a stub `harry_overlay.json` with the placeholder structure
5. CompassBLE package with the protocol skeleton, stubs, and MockGarminDevice
6. Full SwiftUI views for Today, Activity, Health, Settings — working
   against mock data with realistic-looking results
7. RingsView, MetricCard, and other shared components
8. SyncCoordinator wired up
9. Unit tests for FIT parsers (using synthetic files), repository queries,
   and ring math
10. README.md with:
    - Build instructions
    - Architecture overview
    - "How to fill in the BLE port" guide referencing Gadgetbridge source
      paths
    - "How to extend the FIT overlay" guide referencing HarryOnline's
      Google Sheet
    - TestFlight submission checklist (avoiding trademark issues)

The app should build, run in the simulator, and present the full UI populated
with mock data on first launch. The BLE pairing flow should work in the
simulator's mocked mode (showing the AccessorySetupKit sheet and accepting a
mock pair).

Where you must make decisions not specified here, choose the simpler/more
conservative option and add a code comment explaining the decision and
alternatives.

Begin by creating the Xcode project structure, then the data models, then the
FIT package, then the BLE package, then the UI. Show your work at each major
milestone and verify the project builds before moving on.

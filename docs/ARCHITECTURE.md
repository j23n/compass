# Architecture

Compass is a local-first iOS companion app for Garmin fitness watches. It syncs activity, sleep, and health data over BLE, parses the binary FIT format, and persists everything locally with SwiftData. There is no server or cloud component.

---

## Package structure

The project is one Xcode app target plus three local Swift packages.

```
Compass (app target — iOS 18+, SwiftUI)
├── CompassData   — SwiftData models and repository layer
├── CompassFIT    — FIT parser (via FitFileParser), GPX parser, FIT encoder
├── FitFileParser — Vendored FIT profile library (Garmin SDK + augmented fields)
└── CompassBLE    — CoreBluetooth wrapper, Garmin ML v2 / GFDI protocol
```

**Dependency rules:**
- `Compass` imports all three packages.
- `CompassBLE` has no compile-time dependency on `CompassData` or `CompassFIT`. It produces raw FIT bytes that the app routes to `CompassFIT`.
- `CompassFIT` has no dependency on `CompassBLE`. It depends on `CompassData` (for model types) and `FitFileParser` (vendored, for binary FIT decoding). It is a pure parsing/encoding library.
- `CompassData` has no dependency on the other packages. It is a pure persistence layer.

`SyncCoordinator` in the app target is the runtime orchestrator that wires all three packages together.

---

## Directory tree

```
Compass/
├── App/
│   ├── CompassApp.swift           @main; builds ModelContainer, creates DependencyContainer
│   ├── SyncCoordinator.swift      @MainActor orchestrator: BLE events → FIT parsing → SwiftData
│   ├── DependencyContainer.swift  Struct holding all concrete protocol instances
│   └── AppLogger.swift            os.Logger wrapper with LogStore sink (5 categories)
├── Views/
│   ├── ContentView.swift          Root TabView (Today / Activities / Health / Courses)
│   ├── Today/
│   │   ├── TodayView.swift        Dashboard: connection pill, vitals grid, recent activities
│   │   ├── VitalsGridView.swift   2×N grid of MetricCards (HR, HRV, sleep, BB, stress, steps)
│   │   └── SleepStageBar.swift    Horizontal sleep-stage breakdown bar
│   ├── Activity/
│   │   ├── ActivitiesListView.swift  Chronological list with sport-filter chips
│   │   ├── ActivityDetailView.swift  Map + stats + per-metric charts
│   │   ├── ActivityRowView.swift     List row component
│   │   ├── MapRouteView.swift        Live MapKit route with highlighted point
│   │   ├── MapSnapshotView.swift     Static map thumbnail
│   │   └── StatCell.swift            Single stat display (label + value + unit)
│   ├── Health/
│   │   └── HealthDetailView.swift    Full-screen chart detail for one metric (entered from Today's chits)
│   ├── Courses/
│   │   ├── CoursesListView.swift     List of courses with upload-status badge
│   │   ├── CourseDetailView.swift    Map + metadata + upload/delete controls
│   │   └── CourseRowView.swift       List row component
│   └── Settings/
│       ├── SettingsView.swift        Device mgmt, sync controls, logs, about
│       ├── FITFilesView.swift        Browse downloaded FIT files
│       ├── CourseFilesView.swift     Manage course FIT files
│       └── LogsView.swift            In-app debug log viewer with filter
├── ViewModels/
│   └── TodayViewModel.swift          @Observable; today metrics from repositories
├── Components/
│   ├── RingsView.swift               2×2 grid of progress rings
│   ├── RingView.swift                Single circular ring with icon + label
│   ├── MetricCard.swift              Card: title, value, unit, trend sparkline
│   ├── SparklineChart.swift          Inline mini line chart (7–14 points)
│   └── TrendChartView.swift          Line or bar chart with time-range picker
├── Services/
│   ├── WeatherService.swift          Watch requests weather → fetches → returns FIT msg
│   ├── FindMyPhoneService.swift      Watch triggers alert → local notification + sound
│   ├── MusicService.swift            MediaPlayer observer → sends now-playing to watch
│   ├── PhoneLocationService.swift    CoreLocation observer → sends GPS to watch
│   ├── FITFileStore.swift            Persists downloaded FIT files to Documents/
│   ├── CourseFileStore.swift         Persists course FIT files for upload
│   └── LogStore.swift                In-memory rotating log buffer for LogsView
└── Extensions/
    ├── Sport+UI.swift                Display names and SF Symbols for Sport enum
    └── ActivityView.swift            Activity model convenience helpers

Packages/
├── CompassData/
│   ├── Sources/CompassData/
│   │   ├── Models/                   @Model types (see table below)
│   │   ├── Repositories/
│   │   │   ├── ActivityRepository.swift
│   │   │   ├── SleepRepository.swift
│   │   │   ├── HealthMetricsRepository.swift
│   │   │   └── DeviceRepository.swift
│   │   └── MockDataProvider.swift    Generates deterministic sample data for previews
│   └── Tests/CompassDataTests/

├── FitFileParser/
│   ├── Sources/FitFileParser/
│   │   ├── FitFile.swift                Binary FIT reader; produces [FitMessage]
│   │   ├── FitMessage.swift             Per-record interpreted field access
│   │   ├── FitFieldValue.swift          Typed field value (coordinate, time, double, name, invalid)
│   │   ├── rzfit_swift_map.swift        Generated: FIT mesg num → field definitions (14k lines)
│   │   ├── rzfit_swift_reverse_map.swift Generated: field name → mesg num lookups (15k lines)
│   │   ├── Sources/FitFileParserObjc/    Objective-C bridge (fit_convert, fit_crc, dev data)
│   │   └── Tests/                       Unit tests + sample .fit files
│   └── python/                          Profile augmentation pipeline
│       ├── fitsdkparser.py              Parses Profile.xlsx into Swift definitions
│       └── Profile.xlsx                 Garmin SDK + Gadgetbridge + Harry additions
│
├── CompassFIT/
│   ├── Sources/CompassFIT/
│   │   ├── Parsers/
│   │   │   ├── FITTimestamp.swift        Garmin epoch (1989-12-31) ↔ Date
│   │   │   ├── ActivityFITParser.swift   session/lap/record msgs → Activity + TrackPoints
│   │   │   ├── MonitoringFITParser.swift monitoring msgs → HR, stress, BB, steps, respiration
│   │   │   ├── MonitoringResults.swift   Value types returned by monitoring parser
│   │   │   ├── SleepFITParser.swift      sleep msgs → SleepResult + SleepStageResult
│   │   │   ├── MetricsFITParser.swift    hrv/hrv_status_summary msgs → [HRVResult]
│   │   │   └── GPXCourseParser.swift     GPX XML → Course model
│   │   └── Encoders/
│   │       ├── CourseFITEncoder.swift    Course model → FIT binary for upload
│   │       ├── PathSimplification.swift  Douglas-Peucker GPS track simplification
│   │       └── ActivityGPXExporter.swift Activity → GPX for share sheet
│   └── Tests/CompassFITTests/

└── CompassBLE/
    ├── Sources/CompassBLE/
    │   ├── Public/                       Protocol + types visible to app target
    │   │   ├── DeviceManagerProtocol.swift  Testable interface for device operations
    │   │   ├── GarminDeviceManager.swift    Concrete actor implementation
    │   │   ├── MockGarminDevice.swift       Mock for previews and simulator testing
    │   │   ├── DiscoveredDevice.swift       BLE scan result (name, RSSI, identifier)
    │   │   ├── PairedDevice.swift           Connected device (identifier, name, model)
    │   │   ├── SyncProgress.swift           Progress enum: starting → listing → transferring → done
    │   │   ├── ConnectionState.swift        disconnected / connecting / connected / failed
    │   │   ├── FITDirectory.swift           activity / monitor / sleep / metrics
    │   │   ├── PairingError.swift           Error cases for pairing failures
    │   │   └── DeviceServiceCallbacks.swift Callbacks for weather, music, location services
    │   ├── Transport/
    │   │   ├── BluetoothCentral.swift       CBCentralManager wrapper (scan, connect, notify)
    │   │   ├── MultiLinkTransport.swift     ML v2 protocol (CLOSE_ALL, REGISTER_ML, COBS framing)
    │   │   ├── MLRTransport.swift           MLR protocol frame handling
    │   │   ├── FrameAssembler.swift         Reassembles multi-chunk MLR frames
    │   │   ├── HandleManager.swift          Maps GFDI service code → BLE characteristic handle
    │   │   └── CobsCodec.swift              COBS encode/decode
    │   ├── GFDI/
    │   │   ├── GFDIMessage.swift            Base message type and wire encoding
    │   │   ├── GFDIClient.swift             Send/receive dispatcher with type routing
    │   │   ├── MessageTypes.swift           Message type enum (decimal IDs from Gadgetbridge)
    │   │   └── Messages/
    │   │       ├── Response.swift           Generic ACK/NACK (type 5000)
    │   │       ├── DeviceInformation.swift  Device info handshake (watch → phone)
    │   │       ├── AuthNegotiation.swift    Unit ID / auth token exchange
    │   │       ├── Configuration.swift      Capabilities negotiation
    │   │       ├── PostInit.swift           Post-init setup messages
    │   │       ├── SystemEvent.swift        SYNC_READY, SYNC_COMPLETE, etc.
    │   │       ├── FileSync.swift           Directory listing and file transfer
    │   │       ├── WeatherFIT.swift         Weather data in FIT format
    │   │       ├── MusicControl.swift       Now-playing state and control
    │   │       ├── PhoneLocation.swift      Phone GPS pushes
    │   │       └── CourseUpload.swift       Course FIT upload
    │   ├── Sync/
    │   │   ├── FileSyncSession.swift        Manages one file-download session
    │   │   ├── FileUploadSession.swift      Manages one file-upload session
    │   │   └── FileMetadata.swift           File entry from watch directory listing
    │   └── Utils/
    │       ├── Logger.swift                 BLE logger with LogStore sink (5 categories)
    │       ├── ByteReader.swift             Endian-aware binary cursor
    │       ├── CRC16.swift                  CRC-16 checksum validation
    │       └── ProtoEncoder.swift           Minimal protobuf encoder for GFDI messages
    └── Tests/
        ├── CompassBLETests/                 Unit tests (byte reader, CRC, GFDI, frame assembly)
        └── CompassBLEIntegrationTests/      Requires physical device; skipped by default
```

---

## Data flow

```
Fitness Watch (Garmin)
     │
     │  BLE notify characteristic
     ▼
BluetoothCentral          CoreBluetooth wrapper; delivers raw bytes
     │
     │  raw bytes
     ▼
MultiLinkTransport        ML v2 protocol; CLOSE_ALL_REQ → REGISTER_ML_REQ;
                          COBS-decodes each BLE packet; tags frames with handle
     │
     │  COBS-decoded frames
     ▼
FrameAssembler            Reassembles multi-chunk MLR frames into complete messages
     │
     │  complete GFDI message bytes
     ▼
GFDIClient                Deserializes message type; routes to correct handler
     │
     │  DeviceInformation / AuthNegotiation / SystemEvent / FileSync / …
     ▼
GarminDeviceManager       Runs the pairing and sync state machines;
                          accumulates FIT file chunks via FileSyncSession
     │
     │  complete .FIT file bytes (as Data)
     │  exposed through AsyncStream<SyncProgress>
     ▼
SyncCoordinator           @MainActor; receives file data; routes by FIT directory type
     │
     ├──(activity)──────► ActivityFITParser   → Activity + [TrackPoint]
     ├──(monitor)──────► MonitoringFITParser  → HR / stress / BB / respiration / steps
     ├──(sleep)────────► SleepFITParser       → SleepResult + [SleepStageResult]
     └──(metrics)──────► MetricsFITParser     → [HRVResult]
                           ▲
                           └── all parsers use FitFileParser for binary decoding
                               (interpretedField / messageType API)
     │
     │  Swift model objects
     ▼
Repository layer          @MainActor; inserts into ModelContext with deduplication
     │
     │  SwiftData @Model instances
     ▼
SwiftData ModelContainer
     │
     │  @Query / fetch
     ▼
ViewModels (@Observable, @MainActor)
     │
     ▼
SwiftUI Views
```

### Key flows

**Pairing**
1. User taps "Scan for Devices" → `SyncCoordinator.startPairing()` → `deviceManager.discover()` returns `AsyncStream<DiscoveredDevice>`.
2. User selects a device → `SyncCoordinator.pairDevice(_:)` → full GFDI handshake (device info, auth, capabilities, post-init).
3. On success the device is saved as a `ConnectedDevice` in SwiftData; future launches auto-reconnect without re-pairing.

**Sync**
1. User pulls to refresh or taps "Sync Now" → `SyncCoordinator.sync()`.
2. `deviceManager.pullFITFiles(directories:)` requests the watch's file directory, filters for files not yet downloaded, and transfers them chunk by chunk.
3. `SyncCoordinator` receives each file, routes it to the appropriate parser, then inserts results via repositories with deduplication guards.

**Course upload**
1. User imports a GPX file or creates a route → `CourseFileStore` encodes it to FIT via `CourseFITEncoder`.
2. `SyncCoordinator.uploadCourse(_:)` → `deviceManager.uploadCourse()` → `FileUploadSession` chunks and transfers the FIT binary.
3. On success, the `Course` model is updated with `uploadedToWatch = true` and `lastUploadDate`.

**Watch-initiated services**
- `DeviceServiceCallbacks` carries closures for weather requests, Find My Phone events, music control, and phone location — wired from `SyncCoordinator` to the `Service` layer objects.

---

## BLE / protocol stack

```
Layer              File(s)                         Responsibility
──────────────────────────────────────────────────────────────────────
CoreBluetooth      BluetoothCentral.swift           Scan / connect / GATT / notify
ML v2 framing      MultiLinkTransport.swift          COBS encode-decode, handle tags
                   CobsCodec.swift
MLR reassembly     MLRTransport.swift               Sequence tracking
                   FrameAssembler.swift             Fragment → complete frame
GFDI dispatch      GFDIClient.swift                 Type routing, ACK/NACK
                   MessageTypes.swift
GFDI messages      Messages/*.swift                 Per-message encode/decode
File transfer      FileSyncSession.swift            Download state machine
                   FileUploadSession.swift          Upload state machine
                   FileMetadata.swift               Directory entry type
```

The watch always initiates the handshake by sending `DEVICE_INFORMATION`. The phone responds with a generic `RESPONSE` (type 5000), then begins auth negotiation. Message type IDs match the `GarminMessage` decimal values from Gadgetbridge.

---

## SwiftData models

| Model | Source FIT message | Relationships | HealthKit future |
|---|---|---|---|---|
| `Activity` | `session`, `lap` (18, 19) | has-many `TrackPoint` (cascade) | `HKWorkout` |
| `TrackPoint` | `record` (20) | inverse: `Activity` | `HKWorkoutRoute` |
| `SleepSession` | `sleep_level` (55 / 274) | has-many `SleepStage` (cascade) | `HKCategorySample` |
| `SleepStage` | `sleep_level` | inverse: `SleepSession` | `HKCategoryValueSleepAnalysis` |
| `HeartRateSample` | `monitoring` / `hsa_heart_rate_data` (55 / 308) | independent | `HKQuantitySample (.heartRate)` |
| `HRVSample` | `hrv` / `hrv_status_summary` (78 / 370) | independent | `HKQuantitySample (.heartRateVariabilitySDNN)` |
| `StressSample` | `stress_level` / `hsa_stress_data` (57 / 307) | independent | — |
| `BodyBatterySample` | `monitoring` / `hsa_body_battery_data` (55 / 314) | independent | — |
| `RespirationSample` | `respiration_rate` / `hsa_respiration_data` (297 / 306) | independent | `HKQuantitySample (.respiratoryRate)` |
| `StepCount` | `monitoring` (55) | independent | `HKQuantitySample (.stepCount)` |
| `StepSample` | `monitoring` (55) | independent | — |
| `ConnectedDevice` | BLE discovery | independent | — |
| `Course` | GPX / user-created | has-many `CourseWaypoint`, `CoursePOI` (cascade) | — |
| `CourseWaypoint` | Course GPS point | inverse: `Course` | — |
| `CoursePOI` | Point of interest | inverse: `Course` | — |

All models use `uuid: UUID` as the SwiftData primary key. Deduplication during sync uses composite natural keys:
- `Activity`: `(sport, startDate)`
- Timestamped samples: `(timestamp)` uniqueness constraint
- `SleepSession`: `(startDate)` with ±1 hour tolerance

Independent timestamped samples (HR, HRV, stress, etc.) are not related to `Activity` or `SleepSession` via foreign keys; the UI queries by time-range overlap.

---

## Concurrency model

The project uses Swift 6 strict concurrency throughout.

| Component | Isolation | Rationale |
|---|---|---|
| `GarminDeviceManager` | Custom actor | BLE callbacks arrive on arbitrary queues; actor serializes state mutations |
| `SyncCoordinator` | `@MainActor` | Bridges BLE to SwiftData; `ModelContext` must stay on its creation actor |
| Repositories | `@MainActor` | Wrap `ModelContext` operations |
| ViewModels | `@MainActor` | Feed SwiftUI views |
| `FITTimestamp`, parsers | `Sendable` struct | Pure computation; callable from any context |
| `FitFile`, `FitMessage`, `FitFieldValue` | Non-Sendable classes | FitFileParser (Swift 5.3) — used ephemerally within each `parse()` call via `@preconcurrency import` |

`DeviceManagerProtocol` exposes BLE events as `AsyncStream<SyncProgress>`. `SyncCoordinator` consumes this with `for await` on the main actor, so SwiftData writes are sequential and safe.

CoreBluetooth is initialized with `CBCentralManagerOptionRestoreIdentifierKey` for state restoration after system termination. The `bluetooth-central` background mode keeps the BLE connection alive when backgrounded.

---

## Dependency injection

No third-party DI framework. Constructor injection via protocols.

```swift
@MainActor
struct DependencyContainer {
    let modelContainer: ModelContainer
    let activityRepository: any ActivityRepositoryProtocol
    let sleepRepository: any SleepRepositoryProtocol
    let healthMetricsRepository: any HealthMetricsRepositoryProtocol
    let deviceRepository: any DeviceRepositoryProtocol
    let deviceManager: any DeviceManagerProtocol
}
```

`CompassApp` creates the container at launch and injects it into the view hierarchy via SwiftUI's `@Environment`. Tests substitute `MockGarminDevice` and in-memory `ModelContainer` instances. `MockDataProvider` in `CompassData` generates deterministic 30-day sample datasets for previews.

---

## View hierarchy

```
ContentView (TabView)
├── TodayView
│   ├── SleepNightCard           Last night's stages; tap → HealthDetailView (sleep duration trend)
│   ├── VitalsGridView           HR, Resting HR, HRV, Stress, Steps, Active Min, SpO₂
│   │   └── chit tap → HealthDetailView (per-metric chart, day/week/month/year)
│   └── ActivityRowView (recent)
│       └── → ActivityDetailView
├── ActivitiesListView           Sport-filter chips + chronological list
│   └── ActivityDetailView
│       ├── MapRouteView         GPS track; highlights point as chart is scrubbed
│       ├── StatCell (grid)      Duration, distance, pace, calories, avg/max HR, elevation
│       └── TrendChartView       HR / elevation / pace / speed over time
└── CoursesListView
    └── CourseDetailView
        ├── MapRouteView         Course track + POIs
        └── Upload / delete controls

Settings sheet (toolbar)
└── SettingsView
    ├── FITFilesView
    ├── CourseFilesView
    └── LogsView
```

---

## Logging

Two logger families funnel into the same `LogStore`:

| Logger | Package | Categories |
|---|---|---|
| `AppLogger` | Compass app | app, pairing, sync, ui, services |
| `BLELogger` | CompassBLE | ble, transport, gfdi, fileSync, auth |

`LogStore` maintains an in-memory rotating buffer. `LogsView` shows it with time, category, and level filters. Logs can be shared as a `.txt` file via the system share sheet.

---

## Testing

| Suite | Location | Notes |
|---|---|---|
| `CompassDataTests` | `Packages/CompassData/Tests/` | In-memory ModelContainer |
| `CompassFITTests` | `Packages/CompassFIT/Tests/` | Tests use actual .fit files against FitFileParser |
| `CompassBLETests` | `Packages/CompassBLE/Tests/CompassBLETests/` | ByteReader, CRC16, GFDI, FrameAssembler |
| `CompassBLEIntegrationTests` | `Packages/CompassBLE/Tests/CompassBLEIntegrationTests/` | Requires physical Garmin device; not run in CI |

BLE traffic capture: use PacketLogger (Xcode Additional Tools) → `.btsnoop` file → Wireshark, filtering by the Garmin service UUID. Cross-reference with the Gadgetbridge Java source for protocol correctness.

---

## External dependencies

All frameworks are from the Apple SDK — no third-party Swift packages via SPM.

**FitFileParser** is a vendored local package (`Packages/FitFileParser/`) generated from an augmented Garmin SDK profile. The augmentation pipeline lives in `scripts/augment_profile.py` and produces correct field maps for proprietary monitoring, sleep, and metrics messages.

`Foundation`, `SwiftUI`, `SwiftData`, `CoreBluetooth`, `MapKit`, `Charts`, `UserNotifications`, `MediaPlayer`, `CoreLocation`

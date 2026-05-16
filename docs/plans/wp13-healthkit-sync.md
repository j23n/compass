# WP-13 · Apple Health One-Way Sync — Implementation Plan

Goal: mirror every Compass data type into Apple Health, one direction only
(Compass → HealthKit, no reads). Toggle in Settings; full backfill on enable;
incremental export after every BLE sync; idempotent on re-run.

Out of scope: read-back from HealthKit, Stress, Body Battery (no native HK type),
reverse-direction conflict resolution.

The model-table headers in `ARCHITECTURE.md` (`HKWorkout`, `HKCategorySample`,
…) anticipate this work — the SwiftData schema is already shaped for a clean
1:1 export.

---

## Architecture

### New Swift package: `CompassHealth`

```
Compass (app target)
├── CompassHealth          ← NEW (this WP)
│   └── CompassData
├── CompassBLE
├── CompassFIT
│   └── CompassData
└── CompassData
```

`CompassHealth` is a pure persistence-adjacent library: it reads SwiftData
models and writes `HKSample`s. It has no dependency on `CompassBLE` or
`CompassFIT`, mirroring the layering rule called out in `ARCHITECTURE.md`.

### Concurrency

| Component | Isolation | Reason |
|---|---|---|
| `HealthKitExporter` | custom `actor` | HK callbacks land on arbitrary queues; actor serialises writes and the export-state cursor |
| `HealthKitExporterProtocol` | `Sendable` | Lets `SyncCoordinator` hold it across actors and lets tests substitute a fake |
| `HealthSyncStatus` | `@Observable @MainActor` | Drives the Settings row |
| Type-mapping helpers (`Sport+HKActivityType.swift`, …) | pure `Sendable` extensions | Callable from any context |

Read SwiftData on the main actor, hand the resulting value types to the
exporter actor. **Never** pass `@Model` instances across the actor boundary —
extract snapshot structs first.

---

## Capabilities and Permissions

### Entitlements (`Compass/Compass.entitlements`)

Add:
```xml
<key>com.apple.developer.healthkit</key>
<true/>
<key>com.apple.developer.healthkit.access</key>
<array/>   <!-- empty: no clinical-record access -->
```

### Info.plist (`Compass/Info.plist`)

Add **only** the write key — HealthKit accepts share-only apps without the
read description as long as `requestAuthorization(toShare:read:)` passes an
empty read set:

```xml
<key>NSHealthUpdateUsageDescription</key>
<string>Compass writes your Garmin watch's workouts, sleep, heart-rate,
HRV, respiration, blood-oxygen, and step data into Apple Health so it
appears alongside data from other devices.</string>
```

### Authorization model

`HKHealthStore.requestAuthorization(toShare: writeTypes, read: [])`

`writeTypes` (16 total):
- `HKObjectType.workoutType()`
- `HKSeriesType.workoutRoute()`
- `HKCategoryType(.sleepAnalysis)`
- `HKQuantityType(.heartRate)`
- `HKQuantityType(.restingHeartRate)`
- `HKQuantityType(.heartRateVariabilitySDNN)` *(see HRV open question)*
- `HKQuantityType(.respiratoryRate)`
- `HKQuantityType(.oxygenSaturation)`
- `HKQuantityType(.stepCount)`
- `HKQuantityType(.appleExerciseTime)`
- `HKQuantityType(.activeEnergyBurned)`
- `HKQuantityType(.distanceWalkingRunning)`
- `HKQuantityType(.distanceCycling)`
- `HKQuantityType(.distanceSwimming)`
- `HKQuantityType(.swimmingStrokeCount)` *(optional, only if we add stroke later)*

By HealthKit's design we cannot read back the user's authorization decision —
the system returns "determined" regardless. Strategy: write samples
optimistically; if `HKHealthStore.save` fails with `errorAuthorizationDenied`
for a given type, surface "Some data types are not enabled" in Settings with a
deep-link button to `x-apple-health://Sources/<bundle-id>`.

---

## Type Mapping

| Compass model | HealthKit target | Conversion / notes |
|---|---|---|
| `Activity` (no GPS) | `HKWorkout` via `HKWorkoutBuilder` | sport → `HKWorkoutActivityType`; calories, distance, duration |
| `Activity` (with GPS) | `HKWorkout` + `HKWorkoutRoute` | route built from `trackPoints` as `[CLLocation]` |
| `TrackPoint.heartRate` | `HKQuantitySample(.heartRate)` associated to workout | per-trackpoint; bulk-added via `HKWorkoutBuilder.add(_:)` |
| `Activity.pauses` | `HKWorkoutEvent(.pause / .resume)` | paired into the workout builder |
| `SleepSession` | `HKCategorySample(.sleepAnalysis, .inBed)` spanning whole session | optional but recommended by Apple |
| `SleepStage` | `HKCategorySample(.sleepAnalysis, <stage>)` | `.light → .asleepCore`, `.deep → .asleepDeep`, `.rem → .asleepREM`, `.awake → .awake` |
| `HeartRateSample` (unspecified, sleep, active) | `HKQuantitySample(.heartRate)` | `count/min`, instantaneous (start == end) |
| `HeartRateSample` (resting) | `HKQuantitySample(.restingHeartRate)` | daily; collapse to one per day if multiple |
| `HRVSample` | `HKQuantitySample(.heartRateVariabilitySDNN)` **or skip** | see open question |
| `RespirationSample` | `HKQuantitySample(.respiratoryRate)` | `count/min` |
| `SpO2Sample` | `HKQuantitySample(.oxygenSaturation)` | percent → fraction; `value = percent / 100.0`, unit `.percent()` |
| `StepSample` (per-minute) | `HKQuantitySample(.stepCount)` | window `[ts, ts+60s)`; this is the authoritative source |
| `StepCount` (daily) | — | **skipped** to avoid double-count; HK aggregates per-minute samples natively |
| `IntensitySample` | `HKQuantitySample(.appleExerciseTime)` | `value = 1`, unit `.minute()`, window `[ts, ts+60s)` |
| `StressSample`, `BodyBatterySample` | — | no HK type; skipped (per scope decision) |

### `Sport → HKWorkoutActivityType`

Mirror of `Sport.fitSportCode`, new file `Mapping/Sport+HKActivityType.swift`:

```swift
extension Sport {
    var hkActivityType: HKWorkoutActivityType {
        switch self {
        case .running:      .running
        case .cycling:      .cycling
        case .mtb:          .cycling      // HK has no mountain-biking subtype
        case .swimming:     .swimming
        case .walking:      .walking
        case .hiking:       .hiking
        case .strength:     .traditionalStrengthTraining
        case .yoga:         .yoga
        case .cardio:       .mixedCardio
        case .rowing:       .rowing
        case .kayaking:     .paddleSports
        case .skiing:       .downhillSkiing
        case .snowboarding: .snowboarding
        case .sup:          .paddleSports
        case .climbing:     .climbing
        case .boating:      .sailing
        case .other:        .other
        }
    }

    /// Distance quantity type, if the sport accumulates distance.
    var hkDistanceType: HKQuantityType? {
        switch self {
        case .running, .walking, .hiking: HKQuantityType(.distanceWalkingRunning)
        case .cycling, .mtb:              HKQuantityType(.distanceCycling)
        case .swimming:                   HKQuantityType(.distanceSwimming)
        default:                          nil
        }
    }
}
```

---

## Identity, Deduplication, Provenance

### Sync identifier

Every sample carries `HKMetadataKeySyncIdentifier` + `HKMetadataKeySyncVersion`.
HealthKit uses these to upsert — re-export of an already-written sample is a
no-op, which is the foundation that makes both backfill and incremental sync
safe.

Identifier derivation (deterministic, **does not** depend on SwiftData UUIDs
because reparse may regenerate those):

```
workout:        "compass.workout.\(sport).\(startEpoch)"
workout-route:  "compass.route.\(sport).\(startEpoch)"
sleep-session:  "compass.sleep.\(startEpoch)"
sleep-stage:    "compass.sleep.\(startEpoch).\(stageStartEpoch)"
hr:             "compass.hr.\(timestampEpoch)"
hr-resting:     "compass.hr.rest.\(dayEpoch)"
hrv:            "compass.hrv.\(timestampEpoch)"
respiration:    "compass.resp.\(timestampEpoch)"
spo2:           "compass.spo2.\(timestampEpoch)"
step:           "compass.step.\(timestampEpoch)"
intensity:      "compass.intensity.\(timestampEpoch)"
```

`startEpoch` is `Int(date.timeIntervalSince1970)` — second granularity is
enough because our samples never overlap to the sub-second.

Bump `HKMetadataKeySyncVersion` (currently `1`) any time the identifier
*input shape* changes; HealthKit will replace existing samples with the new
shape. Keep a `SyncIdentifier.currentVersion` constant in one place.

### Source attribution

Build one `HKDevice` per `ConnectedDevice`, cached on the exporter actor:

```swift
HKDevice(
    name: connectedDevice.name,
    manufacturer: "Garmin",
    model: connectedDevice.model,
    hardwareVersion: nil,
    firmwareVersion: nil,
    softwareVersion: nil,
    localIdentifier: connectedDevice.peripheralIdentifier?.uuidString,
    udiDeviceIdentifier: nil
)
```

`HKSource` is automatic — every sample shows up under "Compass" in Health →
Sources, which is the deduplication boundary Apple Health uses for ring
calculations.

### Additional metadata

- `HKMetadataKeyExternalUUID` = original Compass model UUID (lets us look up
  the source row from a HealthKit sample if needed later)
- `HKMetadataKeyWasUserEntered` = `false`
- On workouts: `compass.sourceFile` (original FIT filename), `compass.sportRaw`
  (Compass enum raw value)

---

## Implementation Order

Independent tasks where noted; otherwise sequential.

1. **Scaffold `CompassHealth` package + entitlements + plist** (blocker for all)
2. **Authorization flow + Settings toggle UI** (blocker for tasks 3+)
3. **Continuous quantity samples** (HR, HRV, respiration, SpO₂) — easiest, no relationships
4. **Steps and active minutes** — independent
5. **Sleep sessions and stages** — independent
6. **Workouts (no GPS)** — depends on 3 for HR-during-workout strategy
7. **Workout routes (GPS)** — extends 6
8. **`SyncCoordinator` post-sync hook** — wires 3-7 into the live sync
9. **Backfill on enable + cancellable progress** — uses 3-7
10. **Wipe-and-rewrite for parser changes** — schema-version bump + auto-trigger; see "Safe Re-Run" section
11. **Status, error surfacing, manual "Resync All" button**
12. **Tests + `MockHKStore` fake**

Phasing for shipping is in the **Rollout** section.

---

## Task 1 — Package Scaffolding

**Risk: LOW** — new package, no behaviour change to existing code.

### Files

```
Packages/CompassHealth/
├── Package.swift
└── Sources/CompassHealth/
    ├── HealthKitExporter.swift          actor; main public API
    ├── HealthKitExporterProtocol.swift  Sendable interface for tests
    ├── HealthKitAuthorization.swift     authorization + status enum
    ├── HealthSyncStatus.swift           @Observable last-run status
    ├── SyncIdentifier.swift             stable identifier helpers
    └── Mapping/
        ├── Sport+HKActivityType.swift
        ├── SleepStage+HKCategory.swift
        └── HeartRateContext+HKQuantity.swift
```

`Package.swift` exposes a single library product `CompassHealth`, with
`CompassData` as the only dependency. Platform: `.iOS(.v18)`, Swift tools
`5.10` to match siblings.

### `HealthKitExporterProtocol`

```swift
public protocol HealthKitExporterProtocol: Sendable {
    func requestAuthorization() async throws -> HealthAuthorizationResult
    func export(workouts: [Activity]) async throws -> ExportSummary
    func export(sleepSessions: [SleepSession]) async throws -> ExportSummary
    func export(quantitySamples: QuantitySampleBatch) async throws -> ExportSummary
    func exportAll(snapshot: HealthDataSnapshot,
                   progress: @Sendable (ExportProgress) -> Void) async throws -> ExportSummary
}
```

`HealthDataSnapshot` is a Sendable value type containing *plain structs*
extracted from SwiftData rows on the main actor — never `@Model` instances.

### Entitlements + plist

Edit `Compass/Compass.entitlements` and `Compass/Info.plist` as in the
**Capabilities** section above. Add HealthKit framework to the app target in
`Compass.xcodeproj` (auto-handled by entitlement, but verify the
`HealthKit.framework` shows up in *Frameworks, Libraries, and Embedded
Content*).

### Acceptance

- App builds with `CompassHealth` linked.
- Calling `HealthKitExporter().requestAuthorization()` from a debug button
  shows the system sheet on a real device.
- All existing tests still pass; no behavioural change.

---

## Task 2 — Authorization Flow and Settings UI

**Risk: LOW–MEDIUM** — new UI section, no data flow changes.

### `HealthKitAuthorization.swift`

```swift
public enum HealthAuthorizationResult: Sendable {
    case authorized
    case partiallyAuthorized   // user denied at least one type
    case denied
    case unavailable           // !HKHealthStore.isHealthDataAvailable()
}
```

### `HealthKitSyncService` (in app target, `Compass/Services/`)

`@MainActor @Observable` glue between Settings, the exporter, and persistent
state.

State (UserDefaults-backed):
- `healthSyncEnabled: Bool`
- `lastSuccessfulExport: Date?`
- `lastError: String?`
- `lastSummary: ExportSummary?`  (Codable struct)

Methods:
- `enableSync()` — calls `requestAuthorization`, sets toggle, kicks off
  backfill
- `disableSync()` — flips the flag; future syncs skip HK; **does not** delete
  anything from HealthKit (user does that from Health app → Sources)
- `runIncrementalExport()` — called by `SyncCoordinator` after each
  `parseAndFinalize`
- `runFullResync()` — manual button in Settings

### New Settings section (`Compass/Views/Settings/HealthSyncSettingsView.swift`)

In `SettingsView`, insert between `syncSection` and `warningSection`:

```
Section("Apple Health") {
    Toggle("Sync to Apple Health", isOn: $healthEnabled)
    if healthSync.healthSyncEnabled {
        statusRow                         // last sync + counts
        Button("Resync All") { ... }      // full backfill
        Button("Open in Health app") { ... }  // x-apple-health URL
    }
}
```

### Acceptance

- Toggle ON → system sheet → user grants → toggle stays on, backfill task
  starts (visible in `LogsView`).
- Toggle OFF → next BLE sync writes nothing to HealthKit; existing samples
  are retained.
- App relaunch preserves the toggle state.

---

## Task 3 — Continuous Quantity Samples

**Risk: LOW** — straightforward 1:1 mapping, well-trodden HK API.

### `QuantitySampleBatch` (Sendable value type)

```swift
public struct QuantitySampleBatch: Sendable {
    public var heartRate: [HeartRatePoint] = []
    public var restingHeartRate: [HeartRatePoint] = []
    public var hrv: [HRVPoint] = []          // omitted by default — see open Q
    public var respiration: [RespirationPoint] = []
    public var spo2: [SpO2Point] = []
}
```

`HeartRatePoint` etc. are minimal `Sendable` structs (`timestamp`, value,
optional context). Repositories on the main actor build batches; the actor
writes them.

### Batching

`HKHealthStore.save(_ objects: [HKObject])` can comfortably take 1k samples
at once but stalls on 100k+. Chunk every export at 1000 samples per `save`
call. Sleep 0ms between chunks; let cooperative cancellation handle pause.

### Unit reference

```swift
let bpm   = HKUnit.count().unitDivided(by: .minute())
let ms    = HKUnit.secondUnit(with: .milli)
let pct   = HKUnit.percent()         // pass 0...1 fraction
let count = HKUnit.count()
let min   = HKUnit.minute()
```

### HRV — open question

Garmin's `HRVSample.rmssd` is RMSSD; HealthKit only ships SDNN
(`heartRateVariabilitySDNN`). The two are mathematically distinct.

Options (decide before Task 3 ships):
1. **Skip HRV.** Cleanest; Apple Health users get accurate data, just no HRV
   from Compass. Surface "HRV not supported by Apple Health" in Settings.
2. **Write under SDNN** with `compass.unitOriginal = "RMSSD"` metadata. Apple
   Health will label it SDNN — technically incorrect, may confuse third
   parties consuming HRV.

Plan default: **option 1 (skip)** until Apple ships a real RMSSD type. Easy
to revisit; behind a feature flag if the user wants the inaccurate version.

### Acceptance

- After a sync, open Apple Health → Browse → Heart → Heart Rate.
  Per-minute samples from Compass visible under "Show All Data".
- Source filter: only "Compass" + Garmin device name shows for Compass
  samples.
- Re-running export produces zero "new" samples (HK dedupe).

---

## Task 4 — Steps and Active Minutes

**Risk: LOW** — but watch for double-counting.

### Per-minute steps

For each `StepSample` with `steps > 0`:
```swift
HKQuantitySample(
    type: HKQuantityType(.stepCount),
    quantity: HKQuantity(unit: .count(), doubleValue: Double(sample.steps)),
    start: sample.timestamp,
    end: sample.timestamp.addingTimeInterval(60),
    device: garminDevice,
    metadata: [HKMetadataKeySyncIdentifier: "compass.step.\(epoch)",
               HKMetadataKeySyncVersion: 1]
)
```

### Daily aggregates intentionally skipped

If we also wrote `StepCount.steps` per day, HealthKit would expose **both**
the per-minute samples and the day total — and they would be summed,
double-counting steps. The per-minute series is authoritative.

### Active minutes → `appleExerciseTime`

For each timestamp in `IntensitySample`:
```swift
HKQuantitySample(
    type: HKQuantityType(.appleExerciseTime),
    quantity: HKQuantity(unit: .minute(), doubleValue: 1.0),
    start: ts,
    end: ts.addingTimeInterval(60),
    metadata: [...]
)
```

This **does** contribute to the Exercise ring on iPhone (no Apple Watch
required as of iOS 17). Users will see their Garmin activity counted.

### Acceptance

- Apple Health → Activity → Steps shows Compass per-minute data; the day
  total matches Compass's Today screen for the same day.
- With no Apple Watch present, the Exercise ring fills based on Garmin data.

---

## Task 5 — Sleep Sessions and Stages

**Risk: MEDIUM** — sleep merging is the trickiest area in existing code; we
need to export in a way that survives the post-merge cleanup in
`SyncCoordinator.cleanupSleepSessions`.

### Mapping

`SleepStageType → HKCategoryValueSleepAnalysis`:
```swift
extension SleepStageType {
    var hkValue: HKCategoryValueSleepAnalysis {
        switch self {
        case .awake: .awake
        case .light: .asleepCore
        case .deep:  .asleepDeep
        case .rem:   .asleepREM
        }
    }
}
```

### Strategy

For each `SleepSession`:
1. One `inBed` `HKCategorySample` spanning `startDate ... endDate`, sync
   identifier `compass.sleep.inbed.\(epoch)`.
2. One `HKCategorySample` per stage with the matching value.

### Merge-cleanup interaction

`cleanupSleepSessions` may reshape a session's bounds or delete it
post-merge. After every `parseAndFinalize`, the export step runs against
the **final** SwiftData state, not intermediate.

If a session that was previously exported gets deleted by cleanup:
- Stages keep their identifiers `compass.sleep.\(originalStart).\(stageStart)`.
- On next export those identifiers don't appear in the new batch → HK keeps
  the stale ones.
- Mitigation: when a `SleepSession.startDate` changes between exports, run
  `delete(predicate: HKMetadataKeySyncIdentifier == old.inbed.id)` — keep a
  small UserDefaults map `(SleepSession.id → lastExportedStartEpoch)` to detect.
- Accept some staleness in MVP; document the manual cleanup path.

### Acceptance

- Apple Health → Browse → Sleep → "Show All Data" lists all Compass stages
  with correct durations.
- Sleep summary on the Health watch face matches Compass's TodayView sleep
  card to within 5 minutes.
- A session that gets merged across two sync runs results in **one** sleep
  block in Health, not two.

---

## Task 6 — Workouts (no GPS)

**Risk: MEDIUM** — HKWorkoutBuilder is stateful and requires careful
ordering; failures partway through leak partial workouts.

### Builder lifecycle

```swift
let config = HKWorkoutConfiguration()
config.activityType = activity.sport.hkActivityType
config.locationType = activity.sport.isOutdoor ? .outdoor : .indoor
config.swimmingLocationType = .unknown

let builder = HKWorkoutBuilder(healthStore: store,
                               configuration: config,
                               device: garminDevice)
try await builder.beginCollection(at: activity.startDate)

// Pause/resume events
for pause in activity.pauses {
    try await builder.addWorkoutEvents([
        HKWorkoutEvent(type: .pause,  dateInterval: DateInterval(start: pause.start, duration: 0), metadata: nil),
        HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: pause.end,   duration: 0), metadata: nil),
    ])
}

// HR samples
let hrSamples: [HKQuantitySample] = activity.trackPoints
    .compactMap { $0.heartRate.map { hr in makeHRSample(at: $0.timestamp, bpm: hr) } }
try await builder.addSamples(hrSamples)

// Energy
if let cal = activity.activeCalories {
    let energy = HKQuantitySample(
        type: HKQuantityType(.activeEnergyBurned),
        quantity: HKQuantity(unit: .kilocalorie(), doubleValue: cal),
        start: activity.startDate, end: activity.endDate,
        device: garminDevice, metadata: syncMeta)
    try await builder.addSamples([energy])
}

// Distance
if let distType = activity.sport.hkDistanceType, activity.distance > 0 {
    let dist = HKQuantitySample(
        type: distType,
        quantity: HKQuantity(unit: .meter(), doubleValue: activity.distance),
        start: activity.startDate, end: activity.endDate,
        device: garminDevice, metadata: syncMeta)
    try await builder.addSamples([dist])
}

try await builder.endCollection(at: activity.endDate)
let workout = try await builder.finishWorkout()
```

Add to workout metadata at finish:
```swift
[
  HKMetadataKeyExternalUUID: activity.id.uuidString,
  HKMetadataKeySyncIdentifier: "compass.workout.\(sport).\(startEpoch)",
  HKMetadataKeySyncVersion: 1,
  "compass.sourceFile": activity.sourceFileName ?? "",
  "compass.sportRaw": activity.sport.rawValue,
]
```

### Failure handling

If `beginCollection` succeeds but `addSamples` throws partway, call
`builder.discardWorkout()` in a `defer` block. Log and skip the activity;
the next export attempt will re-try.

### Acceptance

- A 1-hour Compass running activity appears in Apple Fitness as a workout
  with correct duration, calories, distance.
- Per-second HR is browsable under the workout detail.
- Pause spans appear correctly (e.g. in the Activity app's HR graph).

---

## Task 7 — Workout Routes (GPS)

**Risk: MEDIUM** — high data volume; HK has documented limits.

### Build the route

```swift
let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: garminDevice)

let locations: [CLLocation] = activity.trackPoints.map { tp in
    CLLocation(
        coordinate: CLLocationCoordinate2D(latitude: tp.latitude, longitude: tp.longitude),
        altitude: tp.altitude ?? 0,
        horizontalAccuracy: 5,
        verticalAccuracy: tp.altitude == nil ? -1 : 10,
        course: -1,
        speed: tp.speed ?? -1,
        timestamp: tp.timestamp
    )
}

// HK accepts chunks; 1000 is a safe ceiling per call.
for chunk in locations.chunked(into: 1000) {
    try await routeBuilder.insertRouteData(chunk)
}

try await routeBuilder.finishRoute(with: workout, metadata: nil)
```

### Order matters

The route must be finished **after** `builder.finishWorkout()` returns —
`finishRoute(with: workout)` requires the workout object. Mixing the two
builders into one method, with the route step gated on a non-nil workout
return.

### Acceptance

- Activity opened in Apple Fitness shows the GPS map.
- Altitude graph mirrors Compass's altitude chart.
- Routes longer than 10k points (long bike rides) upload without timeout.

---

## Task 8 — SyncCoordinator Hook

**Risk: LOW** — additive call at the end of an existing function.

### Insertion point

`SyncCoordinator.parseAndFinalize` at line 561, right after `try? context.save()`:

```swift
private func parseAndFinalize(...) async {
    for entry in entries { ... }
    cleanupSleepSessions(context: context)
    try? context.save()

    // NEW: forward to HealthKit if enabled. Snapshot is built on the main
    // actor from this same context, so the export sees the post-cleanup state.
    if healthSync.healthSyncEnabled {
        await healthSync.runIncrementalExport(context: context,
                                              since: healthSync.lastSuccessfulExport)
    }
}
```

### Snapshot extraction

`HealthKitSyncService.runIncrementalExport(context:since:)` fetches each
model type with `timestamp > since` (or `startDate > since` for activities/sleep),
turns them into the Sendable batch structs, hands them to the exporter
actor, then on success updates `lastSuccessfulExport = max(timestamps)`.

If `since` is nil → falls through to full backfill (Task 9).

### Cancellation

Tie into `SyncCoordinator.cancelSync` — cancelling the sync also cancels the
exporter task via a shared `Task` handle. HealthKit writes that are already
in flight will complete; the cursor won't advance past the last successful
batch.

### Acceptance

- New BLE sync results in matching new samples in Apple Health within ~5s.
- Re-running the same sync produces no duplicates (HK dedupe).
- Disabling Health sync mid-flight cancels cleanly without crashing.

---

## Task 9 — Full Backfill

**Risk: MEDIUM** — high data volume on first run; long backfill may hit
background-task time limits.

### Trigger

- Settings toggle ON for the first time
- "Resync All" button in Settings

### Flow

```swift
func runFullResync() async {
    let snapshot = await buildFullSnapshot()           // main actor
    status = .running(total: snapshot.totalCount, done: 0)

    do {
        let summary = try await exporter.exportAll(snapshot: snapshot,
                                                   progress: { update in
            Task { @MainActor in self.status.update(from: update) }
        })
        lastSuccessfulExport = Date()
        lastSummary = summary
        status = .succeeded
    } catch {
        lastError = error.localizedDescription
        status = .failed
    }
}
```

### Background task

Wrap in `UIApplication.beginBackgroundTask` (mirror existing `SyncCoordinator`
pattern at line 348). Backfill of ~100k samples can take 30–60 s on older
phones; users will background the app halfway through.

If the OS revokes the background task, the cursor (`lastSuccessfulExport`)
ensures the next launch resumes exactly where we left off.

### Memory shape

Iterate by *date window* (one month at a time, oldest → newest), not by
type. This keeps each in-memory batch bounded and lets the UI report
progress as "Month X of Y".

### UI

- Inline progress in Settings: bar + "Exporting: 12,450 / 38,210 samples"
- "Cancel" button → cancels the Task; status becomes `.cancelled`

### Acceptance

- Fresh phone, 6 months of FIT files reparsed locally → toggle ON →
  everything appears in Apple Health within ~3 min.
- Backgrounding the app pauses progress; foregrounding resumes from the
  next batch boundary.

---

## Task 10 — Safe Re-Run After Parser Changes

**Risk: MEDIUM** — the design-critical task that makes the whole exporter
forgiving rather than write-once. Worth getting right because every parser
fix landing in `CompassFIT` is otherwise a potential pollution event in the
user's Apple Health.

### The problem

`HKMetadataKeySyncIdentifier` upserts only when the identifier is **byte-equal**
to a previously written sample. Identifiers are derived from natural keys
(sport + startEpoch, timestampEpoch, etc.). If a parser change shifts those
keys — even by a single second — HealthKit treats it as a brand-new sample
and the old one stays as a duplicate.

Realistic parser-change scenarios that drift keys:
- Activity start-time detection improves (uses first lap rather than session.startTime)
- Sleep boundary trimming changes (stage merge heuristics evolve)
- Step-bucket alignment shifts (per-minute vs per-interval)
- HR sample timestamps use enhanced field with different precision
- A previously-dropped FIT file starts parsing successfully → new samples appear

`reparseLocalFITFiles()` is the existing "developer reset" trigger and is the
natural hook for full reconciliation.

### Strategy: schema-versioned wipe-and-rewrite

Treat HealthKit as a *projection* of SwiftData. When the projection logic
or its inputs change in a breaking way, wipe Compass-sourced data from HK
and re-export from scratch. This is safe because:

1. Compass owns its `HKSource` — `HKQuery.predicateForObjects(from: source)`
   scopes deletion to *only* samples written by this app. The user's Apple
   Watch / Strava / manual entries are never touched.
2. The exporter is already idempotent end-to-end (Task 3 onwards).
3. Re-export is bounded by SwiftData size, not HK history depth.

### Schema version

```swift
public enum CompassExportSchemaVersion {
    /// Bump whenever:
    ///   - A natural key changes (sport→startDate→identifier shape)
    ///   - A new sample type is added
    ///   - Stage→HK value mapping changes
    ///   - Metadata key naming changes
    public static let current = 1
}
```

Stored in UserDefaults under `"healthExportSchemaVersion"`. On every export
entry point, compare `current` against stored:
- Equal → incremental export (Task 8 path)
- Different (or missing) → **full reconciliation**: wipe + backfill

### Wipe primitive

New on the exporter actor:

```swift
public func deleteAllCompassData() async throws -> DeletionSummary {
    let appSource = try await HKSource.default()   // == our app
    let sourcePredicate = HKQuery.predicateForObjects(from: [appSource])

    var deleted: [String: Int] = [:]
    for type in Self.allExportedTypes {            // workouts, route, sleep cat, all quantity types
        let count = try await store.deleteObjects(of: type, predicate: sourcePredicate)
        deleted[type.identifier] = count
    }
    return DeletionSummary(perType: deleted)
}
```

`deleteObjects(of:predicate:)` returns the count of deleted objects. The
source-scoped predicate is the safety harness — no possible deletion path
touches non-Compass samples.

Workout routes are auto-deleted when their parent workout is deleted (HK
cascades), but we list them explicitly to assert success.

### Auto-trigger points

| Trigger | Action |
|---|---|
| App launch with schema-version mismatch | Schedule background `reconcile()`; status row shows "Refreshing Apple Health" |
| `reparseLocalFITFiles()` finishes | Auto-invoke `reconcile()` if Health sync is enabled (no user prompt needed — they just asked for a reparse) |
| "Resync All" button in Settings | Same code path; explicit user gesture |
| FIT file import that materially changes existing rows | Out of scope — accept staleness until the next reparse |

`reconcile()` =
1. `deleteAllCompassData()`
2. `runFullResync()`  (Task 9)
3. Update `healthExportSchemaVersion = current` on success
4. Surface `DeletionSummary` + `ExportSummary` in Settings

### Partial-failure safety

If `deleteAllCompassData()` succeeds but `runFullResync()` fails halfway,
HK is in a "less-than-Compass" state but **never** in a duplicate state.
The next reconcile cycle catches up. UserDefaults `healthExportSchemaVersion`
only advances on full success → the next launch retries until it succeeds.

This is the key invariant the design protects:
> **HealthKit may temporarily contain fewer Compass samples than SwiftData,
> but it will never contain stale or duplicated Compass samples after a
> parser change.**

### Why not finer-grained reconciliation?

Considered: query each type's existing sync identifiers from HK, diff
against the SwiftData snapshot, delete the disappeared and write the new.
Rejected for MVP because:

- HK has no efficient "list all sync identifiers" query — you have to
  fetch full sample objects.
- Diffing 100k+ samples per type is slow and memory-heavy.
- The wipe-and-rewrite approach is ~10 seconds for the wipe and uses
  the same backfill path that's already cancellable + resumable.
- A precise differ is a future optimisation, not a correctness requirement.

### Reparse hook in `SyncCoordinator`

Add to `reparseLocalFITFiles()` immediately before the final return at
line ~628:

```swift
if healthSync.healthSyncEnabled {
    AppLogger.health.info("Auto-reconciling HealthKit after reparse")
    await healthSync.reconcile()
}
```

### Acceptance

- Modify a parser, ship a new build, reparse local FIT files →
  HealthKit reflects the new parser output **without duplicates** and
  without manual cleanup.
- Bump `CompassExportSchemaVersion.current`, relaunch the app → on next
  foreground a "Refreshing Apple Health" status appears and HK is rebuilt.
- During reconcile, killing the app mid-wipe (between delete-types) leaves
  HK partially empty but not duplicated; relaunch resumes.
- The same predicate-from-source query proves in tests that no non-Compass
  sample is ever included in `deleteObjects`.

---

## Task 11 — Status and Observability

**Risk: LOW**

### `HealthSyncStatus`

```swift
@Observable
@MainActor
public final class HealthSyncStatus {
    public enum Phase: Sendable {
        case idle
        case running(total: Int, done: Int)
        case succeeded
        case failed
        case cancelled
    }

    public var phase: Phase = .idle
    public var lastSuccess: Date?
    public var lastError: String?
    public var lastSummary: ExportSummary?
}

public struct ExportSummary: Codable, Sendable {
    public var workoutsAdded: Int
    public var samplesAdded: Int
    public var sleepSessionsAdded: Int
    public var perTypeFailures: [String: Int]   // e.g. ["heartRate": 12]
}
```

### Logging

Add an `AppLogger.health` category alongside the existing five (app,
pairing, sync, ui, services). Every `save` failure goes through it; surfaced
in `LogsView` filter.

### Settings UI surface

```
Apple Health
─────────────
[●] Sync to Apple Health
Last sync · 2 min ago
Exported · 142 workouts, 38,210 samples
[Resync All]  [Open in Health app]
```

On error:
```
⚠ Some samples didn't sync — check Logs
```

---

## Task 12 — Tests

### `MockHKStore`

In-memory fake conforming to the same protocol seam:
```swift
final class MockHKStore: @unchecked Sendable {
    private(set) var savedSamples: [HKSample] = []
    private(set) var savedWorkouts: [HKWorkout] = []
    var simulatedError: Error?
    func save(_ s: [HKObject]) async throws { ... }
}
```

### Test list

| File | Coverage |
|---|---|
| `MappingTests.swift` | `Sport→HKWorkoutActivityType`, `SleepStageType→HKCategoryValueSleepAnalysis`, `HeartRateContext→HKQuantityType` |
| `SyncIdentifierTests.swift` | Stable across reparse (same natural key → same ID); version bump replaces |
| `ExporterTests.swift` | Builds expected `[HKSample]` for each model type; verifies unit conversions |
| `IdempotencyTests.swift` | Run exporter twice over same snapshot → second run produces zero new samples (mock store would otherwise duplicate, so this checks identifier wiring) |
| `BackfillTests.swift` | Date-windowed iteration; cursor advances correctly on partial failure |
| `ReconcileTests.swift` | Schema-version bump triggers wipe + rewrite; second run is idempotent; mid-reconcile failure leaves no duplicates; delete predicate is scoped to the app source only (assert non-Compass samples in the mock store survive) |

Integration test on a real device (manual, documented in
`docs/TESTING.md`): enable sync, observe Apple Health, toggle off/on,
verify no duplicates.

---

## Edge Cases and Open Questions

### HRV (RMSSD vs SDNN)
Decision needed before Task 3 ships. Plan default: **skip**, with a follow-up
WP to revisit if Apple adds RMSSD. Mitigation in Settings: "HRV from your
watch is not supported by Apple Health."

### Reparse interaction
Handled automatically by Task 10. `reparseLocalFITFiles()` invokes
`reconcile()` — wipes Compass-sourced data from HK and re-exports from
scratch. Schema-version bump in `CompassExportSchemaVersion.current`
triggers the same path on app launch, so shipping a new parser version is
also self-healing.

### Compass + Apple Watch on same wrist
User wears both devices for the same workout → two workouts appear in
Apple Fitness, both sourced. HealthKit aggregates HR per-source for the
rings, so no double-counting on Move/Exercise rings. Document the expected
visual behaviour.

### Storage growth
Worst case: 1 yr × 1440 min × 1 step + 1440 × 1 HR + 1440 × 1 intensity
≈ 1.5M samples/yr. HealthKit handles this on-device; backfill memory
bounded by date windowing (Task 9). Disk impact is on the OS, not Compass.

### Per-type denial
HK doesn't tell us which types the user denied. Strategy: optimistic write,
catch `errorAuthorizationDenied` per save call, record per-type failure
count in `ExportSummary.perTypeFailures`, surface a banner in Settings if
any count >0. Deep-link button → `x-apple-health://Sources/com.compass.app`.

### Sleep merge → orphan stages
Detailed in Task 5. MVP: accept some orphan samples; document the manual
fix (delete Compass source data in Health app). Future WP: maintain a
side-table of "previously exported sleep identifiers" and call
`HKHealthStore.deleteObjects(of:predicate:)` when bounds change.

### Activity.id regenerating
Reparse generates new UUIDs. We intentionally key sync identifiers off
*natural keys* (sport + startDate), not UUID, so this is a non-issue for
HK dedupe. `HKMetadataKeyExternalUUID` will be stale after reparse — used
only as a debug breadcrumb, not for matching.

### Natural keys drifting (parser improvements)
Natural keys also drift if a parser change shifts startDate by a second,
re-buckets a sample, or splits a previously-single workout. Task 10's
schema-version + wipe-and-rewrite is the systemic fix; per-WP discipline
is bumping `CompassExportSchemaVersion.current` whenever a parser change
could move a natural key.

---

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Backfill blocks UI thread | medium | Exporter is an actor; all SwiftData reads on main; chunked batches |
| User denies one type silently | high | Per-type failure surface in Settings (Task 10) |
| Workout route exceeds HK insert limits | low | Chunk `insertRouteData` ≤1000 points |
| Duplicate workouts after reparse (same parser version) | medium | Natural-key sync identifier (not UUID) → HK dedupes |
| Duplicates after parser change shifts natural keys | high | Task 10: schema-version bump + wipe-and-rewrite, auto-triggered from reparse and on schema mismatch at launch |
| Wipe accidentally deletes non-Compass HK data | low (catastrophic if it happens) | Deletion is *always* scoped to `predicateForObjects(from: [appSource])`; covered by `ReconcileTests.swift` |
| Backfill killed by OS background time limit | medium | `beginBackgroundTask` + resumable cursor; date-windowed batching |
| HRV ambiguity confuses user | medium | Skip HRV in MVP; clearly labelled in Settings |
| Sleep cleanup leaves orphan HK samples | medium | Accept in MVP; document the manual delete path |
| App Store: "writes too many types" rejection | low | All types map cleanly to HK; precedent set by Garmin Connect, Strava |

---

## Rollout Phases

**Phase 1 — MVP (Tasks 1, 2, 3, 4, 5, 6, 8)** — ~4 days
Workouts without GPS, sleep, continuous samples, steps, active minutes.
Incremental export after each BLE sync. Forward-only (no backfill UI yet,
but the toggle works).

**Phase 2 — GPS + backfill + reconcile (Tasks 7, 9, 10, 11)** — ~3 days
Workout routes, full backfill with progress UI, wipe-and-rewrite on parser
changes, status row.

**Phase 3 — Test coverage and polish (Task 12)** — ~1 day
`MockHKStore`, unit tests, reconcile tests, integration test docs.

**Phase 4 (deferred) — Open questions**
HRV revisit, orphan-sample cleanup, reparse auto-resync.

---

## Acceptance Criteria (whole WP)

- Toggle Apple Health ON in Settings → system permission sheet appears
  listing all 14+ types → user grants → toggle stays on.
- Within 5 s of a BLE sync completing, new samples appear in Apple Health
  (Sources → Compass).
- Workout: appears in Apple Fitness with map, sport icon, calories, HR
  chart matching Compass's activity detail view.
- Sleep: appears in Health → Sleep with stages matching the Compass card.
- HR / SpO₂ / respiration: browsable under Health → Heart / Respiratory /
  Vitals, attributed to Compass + Garmin device name.
- Steps: contribute to the Move and Exercise rings (with no Apple Watch).
- "Resync All" button populates a fresh phone within 3 min for 6 months of
  Garmin data.
- Toggle OFF → next BLE sync writes nothing; existing HK data retained.
- Reparse FIT files → HealthKit is automatically reconciled (Compass-sourced data wiped + rewritten); no duplicate samples in Health, no user prompt required.
- Bump the export schema version, ship a new build → on first foreground after launch, HealthKit is automatically reconciled.
- HRV: not exported in MVP; Settings shows "HRV not supported by Apple
  Health" status line.

---

## Files Changed Summary

### New
- `Packages/CompassHealth/Package.swift`
- `Packages/CompassHealth/Sources/CompassHealth/*` (8 files, listed in Task 1)
- `Packages/CompassHealth/Tests/CompassHealthTests/*` (5 files, listed in Task 11)
- `Compass/Services/HealthKitSyncService.swift`
- `Compass/Views/Settings/HealthSyncSettingsView.swift`

### Modified
- `Compass.xcodeproj/project.pbxproj` — link `CompassHealth`, add HealthKit framework
- `Compass/Compass.entitlements` — `com.apple.developer.healthkit`
- `Compass/Info.plist` — `NSHealthUpdateUsageDescription`
- `Compass/App/CompassApp.swift` — instantiate `HealthKitSyncService`, pass to coordinator
- `Compass/App/SyncCoordinator.swift` — call exporter after `parseAndFinalize` (line ~561) and trigger `healthSync.reconcile()` after `reparseLocalFITFiles` (line ~629)
- `Compass/App/AppLogger.swift` — add `.health` category
- `Compass/Views/Settings/SettingsView.swift` — embed `HealthSyncSettingsView`
- `docs/ARCHITECTURE.md` — add CompassHealth to package list, dependency diagram, data-flow diagram (HK as a downstream of SwiftData), update logging table
- `docs/plans/todo.md` — track WP-13 in-progress, remove from active list on completion

# Architecture

## Module dependency graph

```
+------------------+
|     Compass      |   iOS App Target (SwiftUI)
|  (App, Views,    |
|   ViewModels,    |
|   Components)    |
+--------+---------+
         |
         | depends on
         |
    +----+----+----------+----------+
    |         |                     |
    v         v                     v
+--------+ +----------+    +----------+
|Compass | |Compass   |    |Compass   |
|Data    | |FIT       |    |BLE       |
+--------+ +----------+    +----+-----+
    ^                           |
    |                           | (FIT bytes flow
    |  (parsed data written     |  from BLE into
    |   to SwiftData)           |  FIT parser)
    |                           v
    |                      +----------+
    +----------------------+Compass   |
                           |FIT       |
                           +----------+
```

Dependency rules:
- **Compass** (app target) imports all three packages.
- **CompassBLE** has no compile-time dependency on CompassData or CompassFIT. It produces raw FIT file bytes that the app target routes to CompassFIT for parsing.
- **CompassFIT** has no dependency on CompassData or CompassBLE. It is a pure parsing library.
- **CompassData** has no dependency on the other packages. It is a pure persistence layer.

The app target's `SyncCoordinator` is the orchestrator that wires the three packages together at runtime.

## Data flow

```
Fitness Watch
     |
     | (BLE notify characteristic)
     v
MLR Transport Layer (CompassBLE/Transport)
     |
     | (reassembled MLR frames)
     v
GFDI Message Layer (CompassBLE/GFDI)
     |
     | (file transfer data messages)
     v
File Transfer Handler (CompassBLE/Sync)
     |
     | (complete .FIT file bytes)
     v
SyncCoordinator (Compass/App)
     |
     | (Data buffer)
     v
FIT Decoder (CompassFIT/Parsers)
     |
     | (MonitoringResults, activity records, etc.)
     v
Repository Layer (CompassData/Repositories)
     |
     | (SwiftData @Model objects)
     v
SwiftData ModelContainer
     |
     | (@Query / fetch)
     v
ViewModels (@Observable, @MainActor)
     |
     | (published properties)
     v
SwiftUI Views
```

### Step-by-step

1. **Discovery and pairing**: `GarminDeviceManager` scans for BLE peripherals advertising the Garmin service UUID. The user selects a device, and the manager connects and discovers characteristics.

2. **Authentication**: The GFDI authentication handshake negotiates the connection. This involves exchanging unit IDs and authentication tokens (see `docs/PROTOCOL_REFERENCE.md`).

3. **File directory request**: The app requests the device's file directory (a FIT file listing all available files, their types, sizes, and data IDs).

4. **File transfer**: For each new file (not previously synced), the app requests a download. The device sends the file in chunks via GFDI data transfer messages. The MLR layer handles framing and reassembly.

5. **FIT parsing**: Complete FIT file bytes are passed to `FITDecoder`, which reads the file header, iterates through data records, and applies the field-name overlay to produce structured Swift types.

6. **Persistence**: Parsed records are converted to SwiftData `@Model` objects (Activity, SleepSession, HeartRateSample, etc.) and inserted via the appropriate repository.

7. **UI update**: SwiftUI views observe the SwiftData store through `@Query` macros or through `@Observable` view models that wrap repository queries. Updates propagate automatically.

## SwiftData model overview

### Models and their HealthKit equivalents

| SwiftData Model      | Source FIT Message   | HealthKit Equivalent (future)           |
|---------------------|---------------------|-----------------------------------------|
| `Activity`          | `session`, `lap`    | `HKWorkout`                             |
| `TrackPoint`        | `record`            | `HKWorkoutRoute` location samples       |
| `SleepSession`      | `sleep_level`       | `HKCategorySample` (.sleepAnalysis)     |
| `SleepStage`        | `sleep_level`       | `HKCategoryValueSleepAnalysis`          |
| `HeartRateSample`   | `monitoring`        | `HKQuantitySample` (.heartRate)         |
| `HRVSample`         | `hrv_summary`       | `HKQuantitySample` (.heartRateVariabilitySDNN) |
| `StressSample`      | `stress_level`      | No direct equivalent                    |
| `BodyBatterySample` | `monitoring`        | No direct equivalent                    |
| `RespirationSample` | `monitoring`        | `HKQuantitySample` (.respiratoryRate)   |
| `StepCount`         | `monitoring`        | `HKQuantitySample` (.stepCount)         |
| `ConnectedDevice`   | N/A (BLE discovery) | N/A                                     |

### Model relationships

- `Activity` has many `TrackPoint` (ordered, cascade delete)
- `SleepSession` has many `SleepStage` (ordered, cascade delete)
- All timestamped samples (HR, HRV, stress, etc.) are independent top-level entities keyed by timestamp. They are not related to Activity or SleepSession via SwiftData relationships; instead, the UI queries by time range overlap.

### Identifiers

All models use a `uuid: UUID` as the SwiftData primary key. For deduplication during sync, composite natural keys are used:
- Activities: `(sport, startDate)`
- Samples: `(timestamp)` with a uniqueness constraint
- Sleep sessions: `(startDate)`

## Concurrency model

The project uses Swift 6 strict concurrency throughout.

### Actor isolation

| Component                   | Isolation       | Rationale                                                |
|----------------------------|-----------------|----------------------------------------------------------|
| `GarminDeviceManager`      | Custom actor    | BLE callbacks arrive on arbitrary dispatch queues. The actor serializes state mutations (connection state, transfer buffers). |
| `SyncCoordinator`          | `@MainActor`    | Bridges BLE events to SwiftData writes. SwiftData's `ModelContext` must be used from the actor it was created on; using `@MainActor` keeps it on the main thread alongside the UI. |
| Repositories               | `@MainActor`    | Wrap `ModelContext` operations. Same rationale as SyncCoordinator. |
| ViewModels                 | `@MainActor`    | Feed SwiftUI views, which are always on the main actor.  |
| `FITDecoder`               | Sendable struct | Pure computation with no mutable state. Can be called from any context. |
| `CRC16`, `ByteReader`      | Sendable        | Value types used within the BLE actor's isolation domain. |

### Async sequences

BLE events are exposed as `AsyncStream<SyncProgress>` from `DeviceManagerProtocol`. The `SyncCoordinator` consumes this stream with `for await` on the main actor, so each event is processed sequentially and can safely write to SwiftData.

### Background BLE

CoreBluetooth's `bluetooth-central` background mode allows the app to continue receiving BLE data when backgrounded. The `CBCentralManager` is initialized with `CBCentralManagerOptionRestoreIdentifierKey` to support state restoration after the app is terminated by the system.

## Dependency injection

The project uses protocol-typed initializer injection. No third-party DI framework.

### Approach

1. **Protocols**: Each repository and the device manager expose a protocol (`ActivityRepositoryProtocol`, `DeviceManagerProtocol`, etc.).

2. **DependencyContainer**: A struct in `Compass/App/DependencyContainer.swift` holds concrete instances:
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

3. **Construction**: `CompassApp.swift` creates the container at launch and passes it into the view hierarchy via SwiftUI's environment.

4. **Testing**: Unit tests create the container with mock implementations. The `MockDataProvider` in CompassData provides a convenience factory for this.

### Why not `@Environment`?

SwiftUI's `@Environment` is used to propagate the `ModelContainer` (via `.modelContainer()` modifier). The `DependencyContainer` is passed as an `@Environment` value as well. This keeps dependency resolution explicit and testable without requiring a service locator pattern.

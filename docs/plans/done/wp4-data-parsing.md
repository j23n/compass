# WP-4 · Data Parsing — Implementation Plan

Clustered from `todo.md` and `work-items.md` into implementation-ready tasks.

Core insight: the Instinct Solar 1G sends sleep msg 274 as 20-byte opaque blobs with
offset-encoded stage at byte 19 (81=deep, 82=light, 83=REM, 84–85=awake). Other
Garmin devices use the standard `uint8` layout (0=unmeasurable, 1=awake, 2=light,
3=deep, 4=REM). The parser needs a **device profile** to decide which decoder to
use.

---

## 1. Device Profile system (substructure for all fallbacks)

Introduce a lightweight `DeviceProfile` struct that encodes per-device quirks and
pass it through to parsers (either via init parameter or injected at parse time).

```swift
public struct DeviceProfile: Sendable {
    public var productID: UInt16
    public var sleepMsg274Format: SleepMsg274Format
    public var sedentaryActivityType: UInt8  // 7 (standard) or 8 (Instinct Solar 1G)
}

public enum SleepMsg274Format: Sendable {
    case standard           // field 0 = uint8 level (0-4), field 253 = timestamp
    case instinct20ByteBlob // 20-byte payload, byte 19 = stage (81-85)
}
```

Known profiles:
- Instinct Solar 1G (`productID = 3466`): `.instinct20ByteBlob`, `sedentary = 8`
- Default (all others): `.standard`, `sedentary = 7`

**Files:**
- **New:** `CompassData/Sources/CompassData/DeviceProfile.swift`
- **Modify:** `SleepFITParser` — accept profile via init
- **Modify:** `MonitoringFITParser` — accept profile via init
- **Modify:** `SyncCoordinator` — pass profile from device info at parse time

---

## 2. Instinct Solar 1G sleep epoch decoder

In `SleepFITParser`, handle msg 274 (`sleep_level`) raw bytes when
`profile.sleepMsg274Format == .instinct20ByteBlob`.

The raw `FitMessage` for msg 274 has no `interpretedField` results (opaque blob).
Access raw bytes from the FIT record data directly. Timestamps are derived
from record index × 60s offset relative to session start (records arrive at
~1/min cadence).

| Offset | Size | Type | Meaning |
|--------|------|------|---------|
| 0–15   | 16   | 8 × int16 LE | Accelerometer statistics |
| 16–17  | 2    | uint16 LE | Motion metric: 0 = still, >0 = movement |
| 18     | 1    | uint8 | Ancillary metric (HRV confidence?) |
| 19     | 1    | uint8 | Sleep stage: 81=deep, 82=light, 83=REM, 84–85=awake |

Stage mapping from byte 19:

```
81 → .deep
82 → .light
83 → .rem
84 → .awake
85 → .awake
```

507 records per ~8.5h session (vs. 18 incomplete records from msg 275), making
msg 274 the primary source for sleep staging on this firmware.

**Extras:** bytes 16–17 (motion metric) can be surfaced as a sleep quality
signal if useful, but not required for the initial fix.

**File:** `CompassFIT/Sources/CompassFIT/Parsers/SleepFITParser.swift`

---

## 3. Standard sleep epoch decoder

For devices other than Instinct 1G, msg 274 already has the expected layout:
`field[0]` = level (uint8: 0=unmeasurable, 1=awake, 2=light, 3=deep, 4=rem)
with `field[253]` = timestamp. The existing `parseSleepStage` method handles
this via `interpretedField(key: "sleep_level")?.name`, mapping through
`rzfit_swift_string_from_sleep_level`.

**Work needed:**
- Verify the existing decode path produces correct stages when
  `profile.sleepMsg274Format == .standard`
- If it returns nil (e.g., the FitFileParser enum string doesn't match
  expectations), skip msg 274 and fall back to msg 275 — same as current
  behaviour

**File:** `CompassFIT/Sources/CompassFIT/Parsers/SleepFITParser.swift`

---

## 4. Sleep parser routing

In `SleepFITParser.parse()` switch on `profile.sleepMsg274Format`:

```
.profile.sleepMsg274Format
├── .instinct20ByteBlob → decode msg 274 raw bytes (§2)
├── .standard           → decode msg 274 via interpretedField (§3)
└── both: fall back to msg 275 stage entries if 274 produces no data
```

Session bounds always come from msg 273 (`sleep_data_info`):
- `start = field[253]` (FIT-standard timestamp)
- `end = field[2]`
- `score = field[1]`

Msg 275 (`sleep_stage`) on Instinct 1G has no explicit `duration` field —
spans are derived from consecutive timestamps, final stage extends to session
end from msg 273. This fallback is already handled in `buildSleepResult`.

**File:** `CompassFIT/Sources/CompassFIT/Parsers/SleepFITParser.swift`

---

## 5. Step count inconsistency

**Symptom:** steps correct on Today view, wrong on Health view.

**Data paths:**
- `StepCount` (daily aggregate) — inserted in `SyncCoordinator:548–568`,
  summing all `MonitoringInterval.steps` per day. Read by TodayView → correct.
- `StepSample` (per-interval deltas) — inserted in `SyncCoordinator:540–546`.
  Read by HealthView `stepsData` in `HealthView.swift:58–71` → grouped by hour
  → sum → then `makeTrendBuckets` further aggregates.

**Root cause investigation:**
1. The dedup guard at `SyncCoordinator:532–538` checks `firstTS...lastTS`
   range — if *any* StepSample exists in that range, *all* are skipped, meaning
   subsequent syncs can't add or correct StepSamples for that period
2. `StepSample` insertion filters `interval.steps > 0` — zero-step intervals
   are skipped, which is correct (they contribute nothing), but verify the
   stopwatch interval (activity_type=7/transition) isn't carrying steps
3. HealthView hour-binning uses `Calendar.current.dateInterval(of: .hour, for:)`
   — verify this doesn't produce overlapping or misaligned hour boundaries

**Fix:**
- Change the StepSample dedup from range-based skip to per-timestamp upsert
  (match on exact `timestamp`), allowing incremental syncs to fill gaps
- Add a one-time comparison check at startup or sync: log warning when
  `sum(StepSample.steps)` for a given day ≠ `StepCount.steps` for the same day

**Files:**
- `Compass/App/SyncCoordinator.swift`
- `Compass/Views/Health/HealthView.swift` (potential query fix)
- `Compass/ViewModels/HealthViewModel.swift` (alternative `stepsData` path)

---

## 6. Active minutes HR threshold

**Current:** `MonitoringFITParser:117` assigns 1 intensity minute per monitoring
interval if `activityType ∈ ["running", "cycling", "fitness_equipment",
"swimming", "walking"]`. The allowlist means a 60-min bike ride only counts
if every monitoring interval has `activity_type = cycling`. Real-world data
shows 2 active minutes for 60 min of biking — the activity_type field is
absent or misclassified on most intervals.

**Fix:**
1. For each monitoring message that carries a `heart_rate` field:
   if `heart_rate ≥ 100` → count as 1 intensity minute
2. Fall back to activity-type allowlist when HR field is absent
   (for devices without per-interval HR data)
3. `DeviceProfile.hasHRThresholdIntensity` controls whether HR threshold
   is the primary or fallback method

The `MonitoringInterval` struct's `intensityMinutes` field is already
accumulated per-day into `StepCount.intensityMinutes`. The fix is local to
`MonitoringFITParser.parseMonitoringInterval`.

**File:** `CompassFIT/Sources/CompassFIT/Parsers/MonitoringFITParser.swift`

---

## 7. SpO2 monitoring (new feature)

### 7a · FIT sources

| Message | Source file | Field | Values |
|---------|-------------|-------|--------|
| `hsa_spo2_data` (305) | HSA subtype-58 | `reading_spo2` | pipe-delimited uint8 array; 0=blank, 255=invalid |
| `spo2_data` (269) | standalone | `reading_spo2` | single uint8 |

HSA variant is the primary source; standalone msg 269 is a fallback for
devices without HSA.

### 7b · New types

**MonitoringResults.swift**

```swift
public struct SpO2SampleValue: Sendable, Equatable {
    public let timestamp: Date
    public let percent: Int  // 0–100
}
```

**CompassData model**

```swift
@Model
public final class SpO2Sample {
    public var timestamp: Date
    public var percent: Int  // SpO₂ percentage 0–100

    public init(timestamp: Date, percent: Int) {
        self.timestamp = timestamp
        self.percent = percent
    }
}
```

### 7c · Parser changes

In `MonitoringFITParser`:

- Add `var spo2Samples: [SpO2SampleValue] = []`
- Handle `case .hsa_spo2_data:` — pipe-array decode matching existing
  `parseHSABodyBattery` pattern (key `"reading_spo2"`, valid range 1–100)
- Handle `case .spo2_data:` — single-value decode with `reading_spo2` field
- Collect in `MonitoringData.spo2Samples`

### 7d · Sync insertion

In `SyncCoordinator` monitoring block, after existing insertions:

```swift
for sample in results.spo2Samples {
    context.insert(SpO2Sample(timestamp: sample.timestamp, percent: sample.percent))
}
```

### 7e · Model registration

Add `SpO2Sample.self` to model arrays in:
- `CompassApp.swift` (ModelContainer)
- `ContentView.swift` (preview)
- `HealthView.swift` (#Preview)

### 7f · Health view card (optional, deferred to follow-up PR)

Add a SpO2 section card in `HealthView` under a "Vitals" section:
- Daily average trend chart
- Intraday scatter for Day range
- Use colors / icon consistent with existing cards

### Files created/modified

| File | Action |
|------|--------|
| `CompassData/.../Models/SpO2Sample.swift` | **New** |
| `CompassFIT/.../MonitoringResults.swift` | **Modify** — add `SpO2SampleValue` |
| `CompassFIT/.../MonitoringFITParser.swift` | **Modify** — add HSA + standalone SpO2 parsing |
| `Compass/App/SyncCoordinator.swift` | **Modify** — insert SpO2 samples |
| `Compass/App/CompassApp.swift` | **Modify** — register model |
| `Compass/Views/ContentView.swift` | **Modify** — register model for preview |
| `Compass/Views/Health/HealthView.swift` | **Modify** — add SpO2 card (+ preview model) |

---

## Dependency graph

```
1. DeviceProfile
 ├── 2. Instinct sleep decoder
 ├── 3. Standard sleep decoder
 │    └── 4. Parser routing
 └── 6. Active minutes HR threshold

5. Step count fix       (independent of profile)

7. SpO2 monitoring      (independent; uses profile only for routing)
 ├── 7a–7c Parser
 ├── 7d Sync insertion
 ├── 7e Model registration
 └── 7f Health view card
```

**Recommended order:**

| Phase | Tasks | Depends on |
|-------|-------|------------|
| 1 | DeviceProfile | nothing |
| 2 | 2 + 3 + 4 (sleep) | 1 |
| 3 | 5 (steps) + 6 (active mins) + 7a–7e (SpO2 core) | 1 (but can start in parallel) |
| 4 | 7f (SpO2 UI) | 7a–7e |

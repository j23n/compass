# FIT File Parsing — Implementation Plan

_Written: 2026-04-29_

## Diagnosis

### Sleep (critical)

The `logs.log` from the first sync reveals:

- **Message 274 (`sleep_level`) appears 91, 27, 10, 15 times** in the April sleep files — this is
  the actual minute-by-minute staging data for this firmware. It is **completely unhandled** today.
  The parser only knows about msg 275 (`sleep_stage`) which never appears in these files.
- Every inserted sleep session has **`startDate == endDate`** (0-duration). Cause:
  `sleep_data_info` (msg 273) fields 2/3 (start/end) are either absent or map wrong; with no stage
  records, `buildSleepResult` falls back to `endDate = startDate`.
- The **6 January 2026 sessions** (when the watch wasn't worn) are degenerate: only messages
  0, 23, 276, 24 appear — no staging data, no valid time bounds. They need to be filtered.
- **Message 276 (`sleep_assessment`)** appears in every sleep file and is silently ignored. It
  likely carries overall sleep quality, recovery, and possibly nap summary.
- `SyncCoordinator.swift:316-323` creates a `SleepSession` but **never inserts any `SleepStage`
  records** — stages computed by the parser are thrown away completely.

### Monitoring (critical)

- The 1007-byte monitoring file produces **0 HR, 0 stress, 0 BB, 0 respiration** samples. The
  expected messages (140, 346, 227, 297) are entirely absent. The file is dominated by
  **message 233** (appears 15×), which is completely unhandled.
- Message 233 is likely a consolidated monitoring record in newer Garmin firmware containing HR,
  activity type, steps, and possibly stress/BB inline.
- Only 2 step counts come from msg 55 — the rest of the step/active data is presumably in msg 233.
- `MonitoringResults.swift:6` — the transient `StepCount` struct has only `(timestamp, steps)`,
  while the persistent `CompassData.StepCount` requires `(date, steps, intensityMinutes,
  calories)`. `SyncCoordinator.swift:309` fills `intensityMinutes: 0, calories: 0` as placeholders.

### Activity (bug)

`ActivityFITParser.swift:25-31`:

```swift
private static let fieldTotalDistance: UInt8 = 5  // WRONG — this is the sport field
private static let fieldSessionSport: UInt8 = 5   // correct
```

Both are defined as field 5. In the FIT SDK session message (18), field 5 = `sport` (enum),
field **9** = `total_distance` (uint32, scale 100, metres). Every parsed activity has garbage
distance (sport_enum_value / 100.0 metres).

### Active minutes

Monitoring message 55 contains `activity_type` (field 5) and `active_time` (field 3, scale 1000
seconds), but both are ignored. This is the source of intensity/active minutes data.

---

## Correct FIT field maps (for reference)

### Session (msg 18)

| Field | Name | Type | Scale | Units |
|-------|------|------|-------|-------|
| 253 | timestamp | date_time | — | s |
| 2 | start_time | date_time | — | s |
| 5 | sport | enum | — | — |
| 6 | sub_sport | enum | — | — |
| 7 | total_elapsed_time | uint32 | 1000 | s |
| 9 | total_distance | uint32 | 100 | m |
| 11 | total_calories | uint16 | — | kcal |
| 16 | avg_heart_rate | uint8 | — | bpm |
| 17 | max_heart_rate | uint8 | — | bpm |
| 22 | total_ascent | uint16 | — | m |
| 23 | total_descent | uint16 | — | m |

### Monitoring (msg 55)

| Field | Name | Type | Notes |
|-------|------|------|-------|
| 253 | timestamp | date_time | — |
| 2 | cycles | uint32 | steps = cycles × 2 for walking/running |
| 3 | active_time | uint32 | scale 1000, seconds |
| 4 | active_calories | uint16 | kcal |
| 5 | activity_type | enum | 0=generic, 1=running, 2=cycling, 6=sedentary, 7=stop |

### Sleep level (msg 274) — Garmin proprietary

| Field | Name | Type | Notes |
|-------|------|------|-------|
| 253 | timestamp | date_time | one record per minute |
| 0 | current_activity_type_intensity | uint8 | 0=unmeasurable, 1=awake, 2=light, 3=deep, 4=REM |

---

## Implementation Steps

### Step 1 — Fix activity distance field (trivial, high impact)

**File:** `Packages/CompassFIT/Sources/CompassFIT/Parsers/ActivityFITParser.swift`

- Change `fieldTotalDistance` from `5` → `9`
- Remove the duplicate `fieldSport` constant (keep only `fieldSessionSport = 5`)
- Ascent/descent at fields 22/23 match the SDK; no change needed there

---

### Step 2 — Add `sleep_level` (msg 274) parser

Message 274 is the primary staging mechanism for Instinct Solar firmware. Each record = 1 minute
of sleep tracking. 91 records in the April file = ~91 minutes of tracked sleep.

**New result type** (add to `MonitoringResults.swift` or a new `SleepResults.swift`):

```swift
public struct SleepLevelSample: Sendable {
    public let timestamp: Date
    public let level: Int  // 0=unmeasurable, 1=awake, 2=light, 3=deep, 4=REM
}
```

**Updated `SleepResult`:**

```swift
public struct SleepResult: Sendable {
    public let startDate: Date
    public let endDate: Date
    public let score: Int?
    public let stages: [SleepStageResult]
    public let rawLevelSamples: [SleepLevelSample]  // all 1-min samples, preserved
}
```

**Changes to `SleepFITParser.swift`:**

1. Add constant `sleepLevelMessageNum: UInt16 = 274`
2. Collect `[SleepLevelSample]` from msg 274 records (field 253 = timestamp, field 0 = level)
3. Build session bounds from level samples when msg 273 fields 2/3 are absent:
   - `startDate = levelSamples.first?.timestamp`
   - `endDate = levelSamples.last?.timestamp.addingTimeInterval(60)` (each record = 1 min)
4. Convert level samples into `[SleepStageResult]` by collapsing consecutive same-level records:
   - Level 1 → `.awake`, 2 → `.light`, 3 → `.deep`, 4 → `.rem`, 0 → skip
5. Prefer msg 274-derived stages; fall back to msg 275 stages if no 274 records found

---

### Step 3 — Fix sleep stage persistence in SyncCoordinator

`SyncCoordinator.swift:316-323` currently discards all computed stages.

Fix — after inserting the session, also insert each stage:

```swift
let session = SleepSession(id: UUID(), startDate: result.startDate,
                           endDate: result.endDate, score: result.score)
context.insert(session)

for stageResult in result.stages {
    let stage = SleepStage(startDate: stageResult.startDate,
                           endDate: stageResult.endDate,
                           stage: stageResult.stage)
    stage.session = session
    context.insert(stage)
}
```

---

### Step 4 — Filter degenerate sleep sessions

Add a validation guard in `SleepFITParser.buildSleepResult` (or at the coordinator level):

- Reject sessions where `endDate <= startDate`
- Reject sessions where `duration < 600` seconds (10 minutes)

This eliminates the 6 January ghost entries without any special-casing.

---

### Step 5 — Decode message 233 (monitoring data backbone)

Message 233 is the most uncertain step — it needs field-level inspection from a real sync.

**First pass — add field dump** in `MonitoringFITParser.swift` `default:` case:

```swift
case 233:
    for (fieldNum, value) in message.fields.sorted(by: { $0.key < $1.key }) {
        Self.logger.debug("MSG233 field[\(fieldNum)] = \(String(describing: value))")
    }
```

Run one sync, collect the output, then map fields. Likely structure based on Gadgetbridge source
and community research:

| Field | Probable content |
|-------|-----------------|
| 253 | timestamp |
| 0 | heart_rate (uint8, bpm) |
| 1 | activity_type (enum, same as msg 55 field 5) |
| 2 | intensity or cycles |
| 3 | steps |
| 4 | active_calories |

Once confirmed:
- Add `"233"` entry to `harry_overlay.json`
- Add `case 233` to `MonitoringFITParser.parse()` routing to `parseMonitoringV2(from:)`
- `parseMonitoringV2` feeds HR into `heartRateSamples`, steps/activity into monitoring intervals

Apply the same approach to msg 355 (appears once; lower priority).

---

### Step 6 — Active minutes extraction

From monitoring message 55 (and msg 233 once decoded), derive intensity minutes:

**New result type** to replace the current loose `StepCount`:

```swift
public struct MonitoringInterval: Sendable {
    public let timestamp: Date
    public let steps: Int
    public let activityType: Int       // raw FIT enum
    public let intensityMinutes: Int   // 1 if active (activity_type != 6/7), else 0
    public let activeCalories: Double
}
```

`MonitoringData.stepCounts: [StepCount]` → replace with `intervals: [MonitoringInterval]`

**Day aggregation in SyncCoordinator:**

Group `MonitoringInterval` records by calendar day, then:

```swift
let daySteps = intervals.reduce(0) { $0 + $1.steps }
let dayIntensityMinutes = intervals.reduce(0) { $0 + $1.intensityMinutes }
let dayCalories = intervals.reduce(0.0) { $0 + $1.activeCalories }
context.insert(StepCount(date: day, steps: daySteps,
                         intensityMinutes: dayIntensityMinutes, calories: dayCalories))
```

---

### Step 7 — Add sleep_assessment (msg 276) parsing

Message 276 appears in every sleep file. Add a field dump first (same pattern as step 5).

Probable contents based on Garmin community research:
- Overall sleep score (may overlap with msg 273 field 0)
- Sleep qualifier enum (excellent / good / fair / poor)
- Recovery score or body battery change during sleep

**Model update** — add nullable fields to `SleepSession.swift` (CompassData):

```swift
public var recoveryScore: Int?    // 0-100
public var qualifier: String?     // "excellent", "good", "fair", "poor"
```

Extend `SleepResult` with these values; persist in SyncCoordinator.

---

### Step 8 — Update `harry_overlay.json`

Add entries for newly understood messages:

```json
"21":  { "name": "event",          "fields": { "253": timestamp, "0": event, "1": event_type, "4": data } },
"274": { "name": "sleep_level",    "fields": { "253": timestamp, "0": current_activity_type_intensity } },
"276": { "name": "sleep_assessment", "fields": { ... } },
"233": { "name": "monitoring_v2",  "fields": { ... } }
```

Fields for 276 and 233 to be filled in after the dump runs (steps 5 and 7).

---

### Step 9 — Serializable struct completeness for Apple Health

All result structs currently exist in `MonitoringResults.swift` / `SleepFITParser.swift`.
To prep for eventual HealthKit writes without further model changes:

| Struct | Addition | HK target |
|--------|----------|-----------|
| `HeartRateSampleValue` | `sourceDeviceName: String?` (from msg 0 field 4) | `HKQuantitySample(.heartRate)` |
| `StressSampleValue` | no change needed | no HK equivalent |
| `BodyBatterySample` | no change needed | no HK equivalent |
| `RespirationSample` | no change needed | `HKQuantitySample(.respiratoryRate)` |
| `MonitoringInterval` | replaces `StepCount` (step 6) | `HKQuantitySample(.stepCount)` |
| `SleepLevelSample` | new (step 2) | raw source for `HKCategorySample(.sleepAnalysis)` |
| `SleepResult` | add `rawLevelSamples`, `recoveryScore`, `qualifier` | session metadata |
| `SleepStageResult` | no change needed | `HKCategoryValueSleepAnalysis` |

HealthKit mapping for sleep stages:
- `.awake` → `HKCategoryValueSleepAnalysis.awake`
- `.light` → `HKCategoryValueSleepAnalysis.asleepUnspecified` (or `.asleepCore` on iOS 16+)
- `.deep`  → `HKCategoryValueSleepAnalysis.asleepDeep`
- `.rem`   → `HKCategoryValueSleepAnalysis.asleepREM`

---

### Step 10 — Deduplication guard before insert

Before any SwiftData insert, check for existing records:

- `SleepSession`: skip if a session already exists with `startDate` within ±1 hour of the candidate
- `HeartRateSample`: dedup on `(timestamp, bpm)` — timestamps are fine-grained enough
- `StepCount`: one per calendar day — query first, update if exists rather than insert
- `Activity`: dedup on `(startDate, sport)` pair

---

## File change summary

| File | Change |
|------|--------|
| `ActivityFITParser.swift` | `fieldTotalDistance = 9`; remove duplicate `fieldSport` |
| `SleepFITParser.swift` | Add msg 274 handler; fix session bounds from level samples; min-duration filter |
| `MonitoringFITParser.swift` | Add field dump for msg 233; add msg 233 handler once fields confirmed |
| `MonitoringResults.swift` | Add `SleepLevelSample`; replace `StepCount` with `MonitoringInterval` |
| `SyncCoordinator.swift` | Persist `SleepStage` records; day-aggregate monitoring; dedup guard |
| `harry_overlay.json` | Add msgs 21, 274, 276, 233 |
| `SleepSession.swift` (CompassData) | Add `recoveryScore: Int?`, `qualifier: String?` |

---

## Execution order

| # | Step | Depends on |
|---|------|------------|
| 1 | Fix activity distance field | nothing |
| 2 | Persist sleep stages (step 3) + filter ghost sessions (step 4) | nothing |
| 3 | Add msg 274 sleep_level parser (step 2) | step 2 |
| 4 | Add msg 233 field dump (step 5 first pass) | need one sync run |
| 5 | Full msg 233 monitoring parser (step 5 second pass) | step 4 output |
| 6 | Active minutes (step 6) | step 5 |
| 7 | sleep_assessment (step 7) | field dump run |
| 8 | Update overlay (step 8) | steps 5 + 7 |
| 9 | Apple Health struct prep (step 9) | steps 2–7 |
| 10 | Deduplication guard (step 10) | all inserts stable |

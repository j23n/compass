# WP-9 · Parsing Fixes — Implementation Plan

The WP-4 refactor split parsing into per-message handlers and produces value-typed results. Several regressions slipped through:
- Heart-rate samples land but interval-level HR (used to derive active minutes) doesn't
- Active minutes broken on Today
- Sleep parsing silently produces nothing on some files
- Today's "Steps" headline reads 0 even though per-minute step samples exist
- Activity speed/altitude charts blank for biking/hiking — the watch emits `enhanced_*` fields, the parser only reads the legacy keys

WP-8 (`fitdump`) is a hard prerequisite for verification. Every "fixed" claim in this plan is verifiable with one CLI invocation against a real file.

## Current State

| Area | File:line | Current behaviour |
|---|---|---|
| HR via HSA msg 314 | `MonitoringFITParser.swift:210-215` | Pipe-array HR is decoded into `heartRateSamples` but **does not update `recentHR`**, the rolling reference used for per-interval intensity. |
| HR via msg 55 | `MonitoringFITParser.swift:184-197` | Updates `recentHR` correctly, but newer firmware emits HSA HR instead of msg-55 HR. |
| Intensity-minute threshold | `MonitoringFITParser.swift:26, 146-155` | Hardcoded 100 bpm; falls back to activity-type allowlist if `recentHR == nil`. With HSA-only HR (above), `recentHR` stays nil → fallback runs → undercounts. |
| Daily step upsert | `SyncCoordinator.swift:528-549` | `existing.steps = daySteps` — last sync wins. A mid-day partial sync overwrites the morning's accumulated total with the partial. |
| HR dedup on import | `SyncCoordinator.swift:476-490` | Coarse range check: if **any** HR sample exists in `[firstTS, lastTS]`, drops the **whole batch**. A new sync that overlaps a prior one by one minute throws away the rest. |
| Sleep result discard | `SyncCoordinator.swift:553-587` | `try? parser.parse(...)` returns `nil` silently. Files producing only an assessment (msg 346) without msg 273/275 are dropped. |
| Sleep blob gating | `SleepFITParser.swift:123-141` | Msg-274 blob decode runs only when `profile.usesSleepBlobMessage274 == true`. If `SyncCoordinator` doesn't have the right `productID` yet (e.g. parsing files before pairing completes), the wrong profile is used. |
| Activity altitude / speed | `ActivityFITParser.swift:62, 65` | Reads `altitude` and `speed` only. Modern Garmin (Instinct included) emits `enhanced_altitude` and `enhanced_speed`; the legacy keys are nil. |
| Session aggregates | `ActivityFITParser.buildActivity` | Same issue at session level: `avg_speed`, `max_speed`, `total_ascent`, `avg_altitude` have `enhanced_*` variants on newer watches. |

---

## Implementation Order

1. **Task 1 — Enhanced-field fallbacks** (one-line fix per call site, biggest visible win)
2. **Task 2 — HSA HR updates `recentHR`** (unblocks active-minute tracking)
3. **Task 3 — Intensity threshold + freshness window**
4. **Task 4 — Per-timestamp HR dedup** (replace coarse range check)
5. **Task 5 — Daily step aggregation: max-not-overwrite**
6. **Task 6 — Sleep result is "useful enough"** (assessment-only files keep the archive flag)
7. **Task 7 — Diagnostic logging on parse failures** (silent `try?` is what made these regressions invisible)

Tasks 1–6 are independent; 7 supports all of them.

---

## Task 1 — Enhanced-Field Fallbacks

**Risk: LOW** — additive reads; if `enhanced_*` is nil the legacy field is read, matching today's behaviour.

### `ActivityFITParser.swift` — record (track-point) level

```swift
let altitude = doubleValue(message, key: "enhanced_altitude")
            ?? doubleValue(message, key: "altitude")
let speed    = doubleValue(message, key: "enhanced_speed")
            ?? doubleValue(message, key: "speed")
```

Garmin's profile spec says `enhanced_*` carries higher precision and supersedes the legacy field on devices that support it. The fallback order is "enhanced first, legacy second" — same as Garmin Connect's own importer.

### `ActivityFITParser.swift` — session aggregates

```swift
let avgSpeed   = doubleValue(session, key: "enhanced_avg_speed")
              ?? doubleValue(session, key: "avg_speed")
let maxSpeed   = doubleValue(session, key: "enhanced_max_speed")
              ?? doubleValue(session, key: "max_speed")
let avgAlt     = doubleValue(session, key: "enhanced_avg_altitude")
              ?? doubleValue(session, key: "avg_altitude")
let maxAlt     = doubleValue(session, key: "enhanced_max_altitude")
              ?? doubleValue(session, key: "max_altitude")
let minAlt     = doubleValue(session, key: "enhanced_min_altitude")
              ?? doubleValue(session, key: "min_altitude")
```

`total_ascent` / `total_descent` do not have enhanced variants in the public profile — leave as-is.

### `MonitoringFITParser.swift` — respiration

`respiration_rate` (msg 297) and HSA respiration (msg 306) — verify with `fitdump --raw` whether `enhanced_respiration_rate` appears. If yes, mirror the same fallback.

### Verification

```
swift run --package-path Tools/fitdump fitdump activity_*.fit
# Expect: "altitude: <count>" and "speed: <count>" non-zero on a biking file.
```

**Acceptance criteria**
- A biking activity from Instinct shows non-zero altitude and speed counts in `fitdump`.
- `ActivityDetailView` lists Elevation and Speed in the chart-metric picker for biking and hiking.
- No regression on activities recorded by older watches that emit only legacy fields (covered by the fallback chain).

---

## Task 2 — HSA HR Updates `recentHR`

**Risk: LOW** — single-line addition inside the existing HSA branch.

### `MonitoringFITParser.swift:210-215` (HSA msg 314 HR branch)

After appending each per-second HR to `heartRateSamples`, also write the latest BPM to the rolling reference so the **next** monitoring interval can read it:

```swift
for (offset, bpm) in zip(0..., bpms) where bpm > 0 {
    let ts = baseTS.addingTimeInterval(Double(offset))
    heartRateSamples.append(.init(timestamp: ts, bpm: bpm))
}
if let lastBPM = bpms.last(where: { $0 > 0 }) {
    recentHR = (timestamp: baseTS.addingTimeInterval(Double(bpms.count - 1)), bpm: lastBPM)
}
```

This requires changing `recentHR` from `Int?` to a `(Date, Int)?` tuple — needed for Task 3 (freshness check) anyway.

**Acceptance criteria**
- After parsing a monitoring file with only HSA HR, the active-minute count in `MonitoringResults.intervals` is non-zero (provided HR ≥ threshold for at least one interval).

---

## Task 3 — Intensity Threshold + Freshness Window

**Risk: LOW** — bounded by an explicit time window; defaults preserve current behaviour.

The `recentHR` rolling reference currently has no expiry. If the watch emitted HR at 09:00 and an interval at 14:00 has no HR, the 09:00 value drives the 14:00 intensity decision. That's wrong.

### `MonitoringFITParser.swift`

```swift
private static let hrFreshnessWindow: TimeInterval = 5 * 60   // 5 minutes
private static let intensityHRThreshold = 100                  // bpm

private func intensityMinutes(for interval: Date, activityType: Int) -> Int {
    if let recent = recentHR,
       recent.timestamp.distance(to: interval) <= Self.hrFreshnessWindow,
       recent.bpm >= Self.intensityHRThreshold {
        return 1
    }
    // Fall back to activity-type allowlist (walking / running / etc.) when HR is stale or absent.
    return Self.activeActivityTypes.contains(activityType) ? 1 : 0
}
```

The threshold itself stays at 100 — that matches Garmin's own moderate-intensity boundary. Configurable later if needed.

**Acceptance criteria**
- A monitoring file with sustained HR ≥ 100 in a one-hour window produces exactly 60 intensity minutes for that hour.
- A monitoring file with no HR data falls back to the activity-type allowlist (existing behaviour preserved).

---

## Task 4 — Per-Timestamp HR Dedup

**Risk: LOW–MEDIUM** — replaces a "drop-all" check with a per-row check; correctness improves but doubles the predicate count per import. Acceptable: monitoring files have ~hundreds of HR samples, not millions.

### `SyncCoordinator.swift:476-490`

Today:
```swift
let firstTS = ..., lastTS = ...
// fetch first existing in [firstTS, lastTS]; if any exists → skip the whole batch
```

Replace with one upfront fetch of existing timestamps in the range, then a `Set<Date>` lookup:

```swift
let firstTS = results.heartRateSamples.first!.timestamp
let lastTS  = results.heartRateSamples.last!.timestamp
let existingTimes: Set<Date> = {
    let d = FetchDescriptor<HeartRateSample>(
        predicate: #Predicate<HeartRateSample> { hr in
            hr.timestamp >= firstTS && hr.timestamp <= lastTS
        }
    )
    return Set(((try? context.fetch(d)) ?? []).map(\.timestamp))
}()

for sample in results.heartRateSamples where !existingTimes.contains(sample.timestamp) {
    context.insert(HeartRateSample(timestamp: sample.timestamp, bpm: sample.bpm, context: .resting))
}
```

Apply the same pattern for stress, body battery, respiration, SpO2 — currently they have **no** dedup at all (lines 492–503 insert blindly), which double-inserts on overlapping syncs. WP-9 should fix that too in the same Task.

### A note on `context: .resting`

Today every HR sample is inserted with `context: .resting`, which is wrong — resting HR has a specific meaning (`HealthMetricsRepository.swift:97-115` filters by it). Daytime HR samples should be stored with a `.daytime` (or `.unspecified`) context so resting-HR queries don't pull in workout HR.

This is a small adjacent fix; do it here while we're touching the call site:

```swift
context.insert(HeartRateSample(
    timestamp: sample.timestamp,
    bpm: sample.bpm,
    context: .unspecified                 // monitoring file: no context information
))
```

Add the `.unspecified` case to the `HRContext` enum in `CompassData` if it isn't there. **Migration risk**: existing rows have `.resting`. We don't fix old rows; the next sync writes `.unspecified` for new ones, and the repository's resting filter starts behaving correctly going forward.

**Acceptance criteria**
- Two consecutive syncs that overlap by an hour result in HR sample count equal to `union(set1, set2)`, not `|set1|`.
- Resting-HR query on Today no longer reflects workout-HR samples written by monitoring files.

---

## Task 5 — Daily Step Aggregation: Max-Not-Overwrite

**Risk: LOW** — math change only.

### `SyncCoordinator.swift:541-548`

Today:
```swift
if let existing = existingCounts.first {
    existing.steps = daySteps
    existing.intensityMinutes = dayIntensityMinutes
    existing.calories = dayCalories
}
```

A second sync arriving with only the most recent intervals (Garmin sometimes sends incremental files) will overwrite a fully-aggregated day with a partial.

Two options:

**Option A — Take max per field:**
```swift
existing.steps = max(existing.steps, daySteps)
existing.intensityMinutes = max(existing.intensityMinutes, dayIntensityMinutes)
existing.calories = max(existing.calories, dayCalories)
```

**Option B — Aggregate from `StepSample` rows on every sync:**
Sum all `StepSample` rows for the day and write that into `StepCount`. Source of truth is the per-interval row, not whichever monitoring file came in last.

Recommend **B**. It is a few extra lines but makes `StepCount` a pure derived view. After every monitoring import:

```swift
for day in dayIntervals.keys {
    let dayStart = day
    let dayEnd = calendar.date(byAdding: .day, value: 1, to: day)!
    let stepDescriptor = FetchDescriptor<CompassData.StepSample>(
        predicate: #Predicate { $0.timestamp >= dayStart && $0.timestamp < dayEnd }
    )
    let samples = (try? context.fetch(stepDescriptor)) ?? []
    let total = samples.reduce(0) { $0 + $1.steps }
    // upsert StepCount with `total`, intensityMinutes from interval sum, calories from interval sum
}
```

**Acceptance criteria**
- Today's "Steps" headline matches the sum of `StepSample.steps` for `startOfDay(today)`, regardless of how many monitoring files have been imported.
- A partial mid-day re-sync never decreases the day's step count.

---

## Task 6 — Sleep "Useful Enough" Result

**Risk: LOW** — relaxes a guard.

### `SleepFITParser.swift:268-272`

Today, the parser returns `nil` if there is no start timestamp **and** no stages. That fails for files containing only msg 346 (sleep_assessment) — an assessment with score and qualifier but no per-stage breakdown — which the watch sometimes sends as a separate file from the per-stage data.

Change the guard so an assessment-only result is still returned (with empty `stages`, `startDate = endDate = assessment.timestamp`, score/recovery/qualifier populated). Then in `SyncCoordinator.swift:565-583`:

```swift
if existingSessions.isEmpty {
    let session = SleepSession(...)   // unchanged
    context.insert(session)
    for stageResult in result.stages {
        let stage = SleepStage(...)
        context.insert(stage)
    }
} else if let existing = existingSessions.first,
          existing.score == nil, result.score != nil {
    // Merge: assessment-only file landing after per-stage file fills in missing scores.
    existing.score = result.score
    existing.recoveryScore = result.recoveryScore
    existing.qualifier = result.qualifier
}
```

This both stops the silent drop and merges late-arriving assessment data into an existing session.

`parsedOK` then flips true for assessment-only files → `archiveFITFile` is called → the watch stops re-listing it.

**Acceptance criteria**
- `fitdump sleep_*.fit` for an assessment-only file prints a session with score/recovery/qualifier and zero stages, instead of "no session emitted".
- After two syncs (one with stages, one with assessment) the SwiftData session has both populated.

---

## Task 7 — Diagnostic Logging on Parse Failures

**Risk: LOW** — observability only.

`SyncCoordinator` uses `try? parser.parse(...)` everywhere, which silently swallows errors. Replace with `do/catch` and log:

```swift
do {
    let results = try await parser.parse(data: fileData)
    parsedOK = true
    // …insert…
} catch {
    AppLogger.sync.error("Monitoring parse failed for \(filename): \(error.localizedDescription)")
}
```

For sleep specifically, log when `result.stages.isEmpty && result.score == nil` — that is the "produced nothing useful" case. Doesn't block archiving (Task 6) but tells us when a file is empty so we can stop re-syncing it.

**Acceptance criteria**
- Every parser failure shows up in `LogsView` under the `sync` category with file name and error.
- Successful parses log a one-line summary of counts (already done for monitoring at line 550; mirror for activity / sleep / metrics).

---

## Files to Modify

| File | Tasks |
|---|---|
| `Packages/CompassFIT/Sources/CompassFIT/Parsers/ActivityFITParser.swift` | 1 |
| `Packages/CompassFIT/Sources/CompassFIT/Parsers/MonitoringFITParser.swift` | 1 (respiration), 2, 3 |
| `Packages/CompassFIT/Sources/CompassFIT/Parsers/SleepFITParser.swift` | 6 |
| `Packages/CompassData/Sources/CompassData/Models/HeartRateSample.swift` | 4 (`HRContext.unspecified`) |
| `Compass/App/SyncCoordinator.swift` | 4, 5, 6, 7 |

---

## Verification Plan

For each task, the loop is: build the iOS app (`xcodebuild ... build` only — see CLAUDE.md note), then run `fitdump` against representative `.fit` files exported via the in-app FIT-files share sheet:

| Check | Command / step |
|---|---|
| Enhanced fields | `fitdump --raw activity_*.fit | head -200` shows `enhanced_altitude` / `enhanced_speed` rows |
| Activity charts | Open a biking activity in the app — chart picker lists Elevation + Speed |
| HR recoveries | `fitdump monitor_*.fit` reports non-zero HR sample count |
| Active minutes | Same monitoring file: `fitdump` shows `intensity-min total` non-zero |
| Steps headline | Today view shows steps total equal to `fitdump`'s `steps total` |
| Sleep | `fitdump --profile instinct-solar-1g sleep_*.fit` shows stages; assessment-only files show score |
| Dedup | Sync the same monitoring file twice via the in-app FIT browser; HR sample count is unchanged the second time |

---

## Known Limitations

- **HR context backfill**. Existing rows stay tagged `.resting` after Task 4. We don't migrate them; resting-HR queries get accurate going forward only.
- **Per-minute intensity granularity**. Tasks 2–3 fix the count, but `MonitoringInterval.intensityMinutes` is still 0 or 1 per interval. Hourly intensity for Today/Health (WP-10/WP-11) needs per-interval persistence — out of scope here.
- **Profile detection timing**. `SyncCoordinator.deviceProfile` is set when a device pairs / connects (`SyncCoordinator.swift:163, 189, 221`). If a user imports a `.fit` file *before* pairing, the default profile is used and Instinct sleep blobs decode as empty. Document; not worth solving until import-from-Files actually exists as a feature.
- **Enhanced-field naming drift**. The FIT profile occasionally adds new enhanced variants in later SDK updates. Worth a `grep enhanced_` over `rzfit_swift_map.swift` once a year to catch new ones.

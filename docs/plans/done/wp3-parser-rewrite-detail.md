# WP-3 Parser Rewrite — Detailed Implementation Notes

This document captures everything learned from reading the FitFileParser API and the
existing parsers. Use it as a reference when writing the code so you don't have to
re-read all the source files.

---

## API contract — FitFileParser

### Constructing a FitFile

```swift
// Use .generic for monitoring/sleep files (Garmin-proprietary messages 55, 227, 273–314, 346, 382).
// FitInterpretMesg applies scale/offset and resolves field names from the generated maps.
let fitFile = FitFile(data: data, parsingType: .generic)

// Use .fast for activity files (standard messages 18, 19, 20 only).
// rzfit_swift_build_mesg uses compiled-in SDK structs — faster, but skips unknown messages.
let fitFile = FitFile(data: data, parsingType: .fast)
```

### Accessing fields

```swift
// Field by name — returns FitFieldValue?
message.interpretedField(key: "timestamp")

// All fields
message.interpretedFields()  // -> [String: FitFieldValue]
```

### FitFieldValue properties

| Property      | Type                    | When present                                   |
|---------------|-------------------------|------------------------------------------------|
| `.time`       | `Date?`                 | `date_time` fields (e.g. "timestamp")          |
| `.value`      | `Double?`               | Numeric fields without a declared unit         |
| `.valueUnit`  | `(value: Double, unit: String)?` | Numeric fields with a unit (e.g. "s", "m") |
| `.name`       | `String?`               | Enum strings AND pipe-delimited arrays         |
| `.coordinate` | `CLLocationCoordinate2D?` | position fields (position_lat+_long merged)  |

**Getting a Double regardless of unit:** `fv?.value ?? fv?.valueUnit?.value`

### FitMessageType dispatch

`FitMessageType` = `FIT_MESG_NUM` = `typedef FIT_UINT16` = `UInt16`.
Static lets are declared in an extension on `FitMessageType`. Use them in switch:

```swift
switch message.messageType {
case FitMessageType.monitoring:     ...
case FitMessageType.stress_level:   ...
case FitMessageType.hsa_heart_rate_data: ...
default: break
}
```

For messages with no named constant, declare a private static let:
```swift
private static let sleepSessionEnd: FitMessageType = 276
```

---

## Field name reference (from rzfit_swift_map.swift)

### monitoring (55) — `.generic` mode

| Field # | Name in FitFileParser     | Notes |
|---------|---------------------------|-------|
| 253     | `"timestamp"`             | Date  |
| 3       | `"steps"` / `"cycles"` / `"strokes"` | Subfield: "steps" when activity_type == "walking" or "running" |
| 4       | `"active_time"`           | **NOT active_calories** — old code had this wrong |
| 5       | `"activity_type"`         | String enum: "generic", "running", "cycling", "walking", "sedentary", … |
| 19      | `"active_calories"`       | kcal — field we actually want |
| 26      | `"timestamp_16"`          | uint16 lower bits of Garmin epoch ts |
| 27      | `"heart_rate"`            | uint8 bpm (compact HR variant) |

### stress_level (227)

| Field # | Name                | Notes |
|---------|---------------------|-------|
| 0       | `"stress_level_value"` | 0–100 |
| 1       | `"stress_level_time"`  | date_time → `.time` |

### respiration_rate (297)

| Field # | Name                | Notes |
|---------|---------------------|-------|
| 253     | `"timestamp"`       | Date |
| 0       | `"respiration_rate"` | Double with unit "breaths/min" → use `.valueUnit?.value` |

### sleep_data_info (273)

| Field # | Name                | Notes |
|---------|---------------------|-------|
| 253     | `"timestamp"`       | UTC sleep start |
| 1       | `"sample_length"`   | 60 (seconds per sample, NOT sleep score) |
| 2       | `"local_timestamp"` | Sleep start in user TZ |

### sleep_level (275)  ← FitFileParser name for what we call "sleep_stage"

| Field # | Name          | Notes |
|---------|---------------|-------|
| 253     | `"timestamp"` | Date |
| 0       | `"sleep_level"` | String enum: "unmeasurable", "awake", "light", "deep", "rem" |

No field 1 (confirmed by Gadgetbridge and live data).

### sleep_assessment (346)  ← FitFileParser name for what we call "sleep_stats"

| Field # | Name                     | Notes |
|---------|--------------------------|-------|
| 0       | `"combined_awake_score"` | |
| 6       | `"overall_sleep_score"`  | uint8 0–100 — **the score we want** |
| 8       | `"sleep_recovery_score"` | |

Note: message 276 has **no named entry** in FitFileParser. Use `FitMessageType(276)` or a
private constant. Live data shows field 253 of msg 276 = session end timestamp.

### hsa_heart_rate_data (308)

| Field # | Name          | Notes |
|---------|---------------|-------|
| 253     | `"timestamp"` | Date (start of interval) |
| 1       | `"status"`    | enum string |
| 2       | `"heart_rate"` | **pipe-delimited** uint8 array, bpm; 0=blank, 255=invalid |

### hsa_stress_data (306)

| Field # | Name            | Notes |
|---------|-----------------|-------|
| 253     | `"timestamp"`   | Date |
| 1       | `"stress_level"` | **pipe-delimited** sint8 array; 0–100 valid, <0 = error/off-wrist |

### hsa_respiration_data (307)

| Field # | Name                | Notes |
|---------|---------------------|-------|
| 253     | `"timestamp"`       | Date |
| 1       | `"respiration_rate"` | **pipe-delimited** (type unclear; likely breaths/min ×100 or raw) |

### hsa_body_battery_data (314)

| Field # | Name          | Notes |
|---------|---------------|-------|
| 253     | `"timestamp"` | Date |
| 1       | `"level"`     | **pipe-delimited** sint8 array; 0–100 valid, -16=blank |
| 2       | `"charged"`   | pipe-delimited sint16 delta |
| 3       | `"uncharged"` | pipe-delimited sint16 delta |

### hrv (78)

| Field # | Name    | Notes |
|---------|---------|-------|
| 0       | `"time"` | pipe-delimited R-R intervals in **seconds** (scale already applied by FitInterpretMesg); valid range 0.3–2.0 s |

No timestamp field in hrv (78). Timestamp is inherited from preceding messages.

### hrv_status_summary (370)

| Field # | Name                    | Notes |
|---------|-------------------------|-------|
| 253     | `"timestamp"`           | Date |
| 0       | `"weekly_average"`      | ms |
| 1       | `"last_night_average"`  | ms — **the HRV metric we want** |
| 2       | `"last_night_5_min_high"` | ms |
| 3       | `"baseline_low_upper"`  | ms — **old code wrongly called this "rmssd"** |

### session (18) — `.fast` mode

Scale/offset are already applied by FitFileParser for `.fast` mode:

| Field # | Name                  | Notes |
|---------|-----------------------|-------|
| 253     | `"timestamp"`         | Date |
| 2       | `"start_time"`        | Date |
| 7       | `"total_elapsed_time"` | **seconds** (scale already applied; do NOT divide by 1000) |
| 9       | `"total_distance"`    | **meters** (scale already applied; do NOT divide by 100) |
| 11      | `"total_calories"`    | kcal (no scale) |
| 16      | `"avg_heart_rate"`    | bpm |
| 17      | `"max_heart_rate"`    | bpm |
| 22      | `"total_ascent"`      | meters |
| 23      | `"total_descent"`     | meters |
| 5       | `"sport"`             | string enum |
| 6       | `"sub_sport"`         | string enum |

### record (20) — `.fast` mode

| Field # | Name          | Notes |
|---------|---------------|-------|
| 253     | `"timestamp"` | Date |
| 0+1     | `"position"`  | **merged** into `.coordinate` by interpretedFields() — no separate lat/long |
| 2       | `"altitude"`  | **meters** (scale+offset already applied; do NOT apply manually) |
| 3       | `"heart_rate"` | bpm |
| 4       | `"cadence"`   | rpm |
| 6       | `"speed"`     | **m/s** (scale already applied; do NOT divide by 1000) |
| 13      | `"temperature"` | °C |

---

## HSA array parsing

In `.generic` mode, array fields come back as **pipe-delimited strings** via `.name`.
The first element is dropped due to a bug in `FitInterpretMesg.m`. For 60-sample
intervals that is one dropped sample per minute — acceptable.

```swift
private func parsePipeArray(from message: FitMessage, key: String) -> [Double] {
    guard let str = message.interpretedField(key: key)?.name else { return [] }
    return str.split(separator: "|").compactMap { Double($0) }
}
```

---

## timestamp_16 resolution (monitoring msg 55 compact-HR variant)

Keep `lastFullTimestamp: UInt32` tracked across all messages. Update it from any
`.time` Date by converting back to Garmin epoch:

```swift
if let date = message.interpretedField(key: "timestamp")?.time {
    lastFullTimestamp = UInt32(max(0, date.timeIntervalSince(FITTimestamp.epoch)))
}
```

The `resolveTimestamp16(_:lastFull:)` function is unchanged.

---

## Known bugs fixed by the rewrite

| Bug | Old code | New code |
|-----|----------|----------|
| `monitoringActiveCalories` read field 4 (`active_time`) | `fields[4]` | `interpretedField(key: "active_calories")` (field 19) |
| `rmssdField = 3` in hrv_status_summary is `baseline_low_upper`, not rmssd | `fields[3]` | `interpretedField(key: "last_night_average")` (field 1) |
| Message 140 dispatch in monitoring reads physiological_metrics | removed | removed |
| Message 346 dispatch in monitoring reads sleep_stats | removed | removed |
| sub_sport 51 mapped to yoga — actually "track_me" | `case 51: return .yoga` | `case "pilates": return .yoga` (sub_sport 44) |
| sport 13 mapped to cardio — actually "alpine_skiing" | `case 13: return .cardio` | `case "fitness_equipment": return .cardio` |
| activity-file overlay.apply() call in default case | present | removed (no overlay) |

---

## Sport / sub_sport string values (from rzfit_swift_string_from_sport/sub_sport)

```
sport strings: "generic"(0), "running"(1), "cycling"(2), "fitness_equipment"(4),
               "swimming"(5), "training"(10), "walking"(11), "hiking"(17),
               "paddling"(19)

sub_sport strings: "yoga"(43), "pilates"(44), "strength_training"(20),
                   "cardio_training"(26)
```

New `mapSport` logic:
- sub_sport "yoga" → `.yoga`
- sub_sport "pilates" → `.yoga`
- sub_sport "strength_training" → `.strength`
- sport "running" → `.running`
- sport "cycling" → `.cycling`
- sport "swimming" → `.swimming`
- sport "walking" → `.walking`
- sport "hiking" → `.hiking`
- sport "fitness_equipment" → `.cardio`
- default → `.other`

---

## Activity type → Int mapping (MonitoringInterval.activityType stays Int)

```swift
private func activityTypeInt(_ name: String) -> Int {
    switch name {
    case "running":           return 1
    case "cycling":           return 2
    case "transition":        return 3
    case "fitness_equipment": return 4
    case "swimming":          return 5
    case "walking":           return 6
    case "sedentary":         return 8  // NOT 7 — confirmed from USB dump
    default:                  return 0  // generic
    }
}
```

Change `lastCyclesByType` from `[Int: Int]` to `[String: Int]` (keyed by activity_type
string, avoiding the need to convert back to int for the lookup).

`intensityActivityTypes` changes from `Set<Int>` to `Set<String>`:
```swift
["running", "cycling", "fitness_equipment", "swimming", "walking"]
```

---

## Files to write / delete

### Write (rewrite)
- `Packages/CompassFIT/Sources/CompassFIT/Parsers/FITTimestamp.swift` — remove `date(from: FITFieldValue)` (kills FITFieldValue dependency)
- `Packages/CompassFIT/Sources/CompassFIT/Parsers/MonitoringFITParser.swift`
- `Packages/CompassFIT/Sources/CompassFIT/Parsers/SleepFITParser.swift`
- `Packages/CompassFIT/Sources/CompassFIT/Parsers/MetricsFITParser.swift`
- `Packages/CompassFIT/Sources/CompassFIT/Parsers/ActivityFITParser.swift`
- `Packages/CompassFIT/Tests/CompassFITTests/FITDecoderTests.swift` — replace with FitFileParser smoke tests
- `Packages/CompassFIT/Tests/CompassFITTests/OverlayTests.swift` — replace with parser smoke tests

### Modify
- `Packages/CompassFIT/Package.swift` — remove `.process("Resources")` target resource

### Delete
- `Packages/CompassFIT/Sources/CompassFIT/Parsers/FITDecoder.swift`
- `Packages/CompassFIT/Sources/CompassFIT/Resources/harry_overlay.json`
- `Packages/CompassFIT/Sources/CompassFIT/Overlay/FieldNameOverlay.swift`
- `Packages/CompassFIT/Sources/CompassFIT/Overlay/OverlayModels.swift`
- `Packages/CompassFIT/Sources/CompassFIT/Overlay/HarryOverlayNotes.swift`

---

## Parser-by-parser implementation notes

### FITTimestamp.swift
Remove `date(from: FITFieldValue)` — the only method that references `FITFieldValue`.
Keep:
- `epoch: Date` static property
- `date(fromFITTimestamp: UInt32) -> Date`

### MonitoringFITParser.swift
```
imports: FitFileParser, CompassData
init: no overlay parameter
parse: FitFile(data: data, parsingType: .generic)

switch dispatch on FitMessageType:
  .monitoring          → parseMonitoringHR + parseMonitoringInterval
  .stress_level        → parseStress
  .respiration_rate    → parseRespiration
  .hsa_heart_rate_data → parseHSAHeartRate
  .hsa_stress_data     → parseHSAStress
  .hsa_respiration_data→ parseHSARespiration
  .hsa_body_battery_data→ parseHSABodyBattery
  233 (private const)  → logger.debug (field dump)
  318 (private const)  → logger.debug (field dump)
  default              → break (no overlay lookup)

lastFullTimestamp: UInt32 — update from "timestamp"?.time converted back to Garmin epoch
activityType: String (from "activity_type"?.name)
steps: "steps"?.value when activity_type is "walking"/"running" else 0
active_calories: "active_calories"?.value ?? ?.valueUnit?.value   ← FIXED from field 4
```

### SleepFITParser.swift
```
imports: FitFileParser, CompassData
init: no overlay parameter
parse: FitFile(data: data, parsingType: .generic)

private static let sleepSessionEnd: FitMessageType = 276

switch dispatch on FitMessageType:
  .sleep_data_info      → capture start timestamp from "timestamp"?.time
  .sleep_level          → parseSleepStage (returns (Date, SleepStageType)?)
  .sleep_data_raw       → skip (opaque bytes)
  sleepSessionEnd (276) → capture end timestamp from "timestamp"?.time
  .sleep_assessment     → capture overall score from "overall_sleep_score"?.value
  .sleep_restless_moments → logger.debug
  default               → break

parseSleepStage returns (timestamp: Date, stage: SleepStageType)? directly — no int mapping step.
mapSleepStageString(_ name: String) -> SleepStageType?:
  "awake" → .awake
  "light" → .light
  "deep"  → .deep
  "rem"   → .rem
  else    → nil (log warning)
```

### MetricsFITParser.swift
```
imports: FitFileParser, CompassData
init: no overlay parameter
parse: FitFile(data: data, parsingType: .generic)

switch dispatch on FitMessageType:
  .hrv               → update currentTimestamp; extractRRInterval → HRVResult
  .hrv_status_summary→ "timestamp"?.time + "last_night_average" → HRVResult  ← FIXED
  default            → update currentTimestamp from "timestamp"?.time; break

extractRRInterval(from message: FitMessage) -> Double?:
  1. Try "time"?.name → split by "|" → take first valid element
  2. Try "time"?.value directly
  3. Valid range: 0.3 ≤ v ≤ 2.0 (seconds)
```

### ActivityFITParser.swift
```
imports: FitFileParser, CompassData
init: no overlay parameter
parse: FitFile(data: data, parsingType: .fast)

switch dispatch on FitMessageType:
  .session → capture first session message
  .record  → parseTrackPoint
  .lap     → logger.debug
  default  → break

parseTrackPoint:
  timestamp: "timestamp"?.time
  position: "position"?.coordinate  (lat+long merged by interpretedFields)
  altitude: "altitude"?.value ?? ?.valueUnit?.value  (already in meters — NO /5 - 500)
  heart_rate: "heart_rate"?.value
  cadence: "cadence"?.value
  speed: "speed"?.value ?? ?.valueUnit?.value  (already in m/s — NO /1000)
  temperature: "temperature"?.value ?? ?.valueUnit?.value

buildActivity:
  startDate: "start_time"?.time ?? "timestamp"?.time
  duration: "total_elapsed_time"?.value ?? ?.valueUnit?.value  (already seconds — NO /1000)
  distance: "total_distance"?.value ?? ?.valueUnit?.value      (already meters — NO /100)
  activeCalories: "total_calories"?.value ?? ?.valueUnit?.value
  avgHR: "avg_heart_rate"?.value
  maxHR: "max_heart_rate"?.value
  ascent: "total_ascent"?.value ?? ?.valueUnit?.value
  descent: "total_descent"?.value ?? ?.valueUnit?.value
  sport: mapSport(from: message)

mapSport uses string names — see table above
```

### Tests (FITDecoderTests.swift → replace entirely)
The old tests tested the now-deleted FITDecoder. Replace with:
- A smoke test that constructs a minimal FIT file and parses it with FitFile
- Verify FITTimestamp.date(fromFITTimestamp: 0) == 1989-12-31 UTC (the only thing kept)

### Tests (OverlayTests.swift → replace entirely)  
The old tests tested the now-deleted FieldNameOverlay. Replace with:
- A smoke test confirming MonitoringFITParser.init() works (no crash)
- A smoke test confirming SleepFITParser.parse(data: Data()) throws or returns nil gracefully

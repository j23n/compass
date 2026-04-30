# FIT Messages — Compass Reference

_Source-derived from `Packages/CompassFIT/Sources/CompassFIT/Parsers/*.swift` and
`Encoders/CourseFITEncoder.swift`. External references: Garmin FIT SDK (`profile.py`),
HarryOnline Garmin FIT extensions spreadsheet, Gadgetbridge `FieldDefinition.java` and
`FileType.java`, plus live captures from an Instinct Solar 1G (firmware 19.1)._

This document catalogues every FIT global message number that Compass parses or emits
today, grouped by file role. For the wire format underlying these messages, see
[`format.md`](format.md); for the timestamp shortcut, see
[`compressed-timestamps.md`](compressed-timestamps.md). For per-device quirks (especially
Instinct Solar 1G's divergent layouts for msgs 233 and 274), cross-link to
[`../instinct/device-reference.md`](../instinct/device-reference.md).

---

## Conventions

- "Field #" is the FIT field-definition number used in definition records (the key by
  which Compass parsers look up values: `message.fields[N]`).
- "Type" gives the Garmin FIT base type. See [`format.md`](format.md) §4 for the byte
  encoding.
- "Units" is what Compass converts to before exposing the value (semicircles → degrees,
  scaled-int → meters, etc.).
- "Source" indicates origin of the field map: **FIT SDK** = official `profile.py`/Profile
  spreadsheet; **HarryOnline** = HarryOnline Garmin FIT extensions spreadsheet; **live**
  = empirically confirmed from a real Garmin file Compass has parsed; **inferred** =
  best-guess from context, not yet seen on the wire.
- A leading `0x...` in a field row means base-type-byte for clarity in tricky cases
  (HSA arrays, course_point, etc.).

Field 253 (`timestamp`, `date_time`, uint32 Garmin epoch) is universal across virtually
every message and is omitted from row tables when its semantics are obvious.

---

## File roles in Compass

| Garmin path                   | Subtype | Compass parser              | Messages used                        |
|-------------------------------|--------:|-----------------------------|--------------------------------------|
| `/GARMIN/Activity/*.fit`      | 4       | `ActivityFITParser`         | 18, 19, 20, 21, 23, 34               |
| `/GARMIN/Monitor/*.fit`       | 32      | `MonitoringFITParser`       | 55, 140, 162, 227, 233, 297, 346     |
| `/GARMIN/MonitorHealth/*.fit` | 58      | `MonitoringFITParser`       | 162, 306, 307, 308, 314, 318         |
| `/GARMIN/Sleep/*.fit`         | 49      | `SleepFITParser`            | 273, 274, 275, 276, 382              |
| `/GARMIN/Metrics/*.fit`       | 44      | `MetricsFITParser`          | 78, 370                              |

`CourseFITEncoder` produces files with subtype 6 (course) using messages 0, 19, 20, 31, 32.

---

# 1. Activity messages

Source: `Packages/CompassFIT/Sources/CompassFIT/Parsers/ActivityFITParser.swift`. Parser
constants at lines 16-42.

## Message 18 — `session`

The summary record at the end of an activity FIT file. Compass takes the first session
encountered (`ActivityFITParser.swift:65-69`).

| Field # | Name                | Type      | Units | Notes                                                          |
|--------:|---------------------|-----------|-------|----------------------------------------------------------------|
| 253     | timestamp           | uint32    | s     | End of session (Garmin epoch)                                  |
| 2       | start_time          | uint32    | s     | Activity start                                                 |
| 5       | sport               | enum      | —     | 0=generic 1=running 2=cycling 5=swimming 10=training 11=walking 13=fitness_equipment 17=hiking 19=yoga 20=strength_training |
| 6       | sub_sport           | enum      | —     | 43=yoga, 51=pilates (sport 10/training on Garmin)              |
| 7       | total_elapsed_time  | uint32    | ms    | Scale 1000; divide by 1000 for seconds                         |
| 9       | total_distance      | uint32    | cm    | Scale 100; 0xFFFFFFFF = invalid sentinel                       |
| 11      | total_calories      | uint16    | kcal  | —                                                              |
| 16      | avg_heart_rate      | uint8     | bpm   | —                                                              |
| 17      | max_heart_rate      | uint8     | bpm   | —                                                              |
| 22      | total_ascent        | uint16    | m     | —                                                              |
| 23      | total_descent       | uint16    | m     | —                                                              |

Sport mapping logic at `ActivityFITParser.swift:176-198`. Sub-sport overrides take priority
because Garmin encodes yoga as `sport=10/training, sub_sport=43`.

Source: FIT SDK; field numbers verified against parser source and live activity files.

## Message 19 — `lap`

Per-lap summary. Compass currently logs the presence of lap messages but does not surface
them to the data model (`ActivityFITParser.swift:76-78`).

`CourseFITEncoder` emits a single lap with these fields (`CourseFITEncoder.swift:243-300`):

| Field # | Name                  | Type   | Units | Notes                              |
|--------:|-----------------------|--------|-------|------------------------------------|
| 253     | timestamp             | uint32 | s     | Lap end                            |
| 0       | event                 | enum   | —     | 0 = TIMER                          |
| 1       | event_type            | enum   | —     | 0 = START                          |
| 2       | start_time            | uint32 | s     | Lap start                          |
| 3       | start_position_lat    | sint32 | semic | Semicircles                        |
| 4       | start_position_long   | sint32 | semic | —                                  |
| 7       | total_elapsed_time    | uint32 | ms    | 0xFFFFFFFF if no timing data       |
| 9       | total_distance        | uint32 | cm    | —                                  |

Source: FIT SDK.

## Message 20 — `record`

Per-trackpoint record. Read at `ActivityFITParser.swift:71-74`, parsed at lines 98-125.

| Field # | Name           | Type   | Units    | Notes                                          |
|--------:|----------------|--------|----------|------------------------------------------------|
| 253     | timestamp      | uint32 | s        | Garmin epoch                                   |
| 0       | position_lat   | sint32 | semic    | degrees = raw × 180/2³¹                        |
| 1       | position_long  | sint32 | semic    | —                                              |
| 2       | altitude       | uint16 | m        | metres = (raw / 5) − 500                       |
| 3       | heart_rate     | uint8  | bpm      | —                                              |
| 4       | cadence        | uint8  | rpm/spm  | 0xFF = invalid                                 |
| 5       | distance       | uint32 | cm       | Cumulative; scale 100                          |
| 6       | speed          | uint16 | mm/s     | Scale 1000 (m/s = raw/1000)                    |
| 13      | temperature    | sint8  | °C       | Identity                                       |

Compass requires fields 253, 0, and 1 to construct a `TrackPoint`; everything else is
optional (`ActivityFITParser.swift:99-104`).

`CourseFITEncoder` emits records with fields 253, 0, 1, 2, 4, 5 (no heart-rate or speed).
See `CourseFITEncoder.swift:302-348` and §"Course encoding" below.

Source: FIT SDK.

## Message 21 — `event`

Compass does not actively decode msg 21 in the current parsers, but it is listed in
`harry_overlay.json` and recognised when present:

| Field # | Name        | Type   | Units | Notes |
|--------:|-------------|--------|-------|-------|
| 253     | timestamp   | uint32 | s     | —     |
| 0       | event       | enum   | —     | —     |
| 1       | event_type  | enum   | —     | —     |
| 4       | data        | uint32 | —     | —     |

Source: FIT SDK / HarryOnline overlay.

## Message 23 — `device_info`

Reserved/standard FIT message containing manufacturer, product, serial number, software/
hardware version, and the timestamp at which the device emitted the record. Compass does
not currently extract individual fields from msg 23 — it appears in activity files and is
ignored at parse time. Used elsewhere in the GFDI sync stack to identify the watch model;
see [`../instinct/device-reference.md`](../instinct/device-reference.md).

Source: FIT SDK.

## Message 34 — `activity`

Top-level activity summary referencing one or more sessions. Compass does not extract
fields from msg 34 today; the `Activity` model is built from the session (msg 18) data
only. The message is recognised by the decoder and passes through `overlay.apply` for
debug logging if present (`ActivityFITParser.swift:80-85`).

Source: FIT SDK.

---

# 2. Monitoring messages

Source: `Packages/CompassFIT/Sources/CompassFIT/Parsers/MonitoringFITParser.swift`. Parser
constants at lines 19-73.

## Message 55 — `monitoring`

Per-minute step/activity record in `/GARMIN/Monitor/*.fit`.

| Field # | Name                              | Type   | Units    | Notes                                            |
|--------:|-----------------------------------|--------|----------|--------------------------------------------------|
| 253     | timestamp                         | uint32 | s        | Garmin epoch                                     |
| 2       | cycles                            | uint32 | cycles   | Cumulative; **always 0 on Instinct Solar 1G fw 19.1** — see below |
| 3       | steps / active_time               | uint32 | steps OR ms | FIT subfield: `steps` (cumulative since midnight) when activity_type ∈ {1, 6}; otherwise `active_time` (ms, scale 1000) |
| 4       | active_calories                   | uint16 | kcal     | —                                                |
| 5       | activity_type                     | enum   | —        | 0=generic 1=running 2=cycling 3=transition 4=fitness_equipment 5=swimming 6=walking **8=sedentary** 254=invalid (NOT 7 on Instinct Solar — confirmed via USB FIT dump) |
| 24      | current_activity_type_intensity   | uint8  | packed   | bits[2:0] = activity_type, bits[7:3] = intensity (FIT spec) |
| 26      | timestamp_16                      | uint16 | s        | Compact-HR variant: lower 16 bits of Garmin epoch |
| 27      | heart_rate                        | uint8  | bpm      | Compact-HR variant: only on some firmwares (e.g. Instinct 2 Solar Surf) |
| 29      | (cumulative)                      | uint16 | —        | Separate cumulative field; not packed intensity   |

The compact-HR variant resolves field 26 against `lastFullTimestamp` with rollover
detection at `MonitoringFITParser.swift:300-308`.

### Steps semantics

Field 3 is a FIT *subfield*: its meaning depends on the value of field 5 (activity_type).
On Instinct Solar 1G fw 19.1 the value is the **raw cumulative step count since midnight,
no ×2 scaling** — Compass computes the per-interval delta in
`MonitoringFITParser.swift:217-227`. Field 2 (`cycles`) is always 0 on this firmware and is
ignored.

### Intensity-minutes counting (bug fix `1394778`)

Only purposeful-movement activity types contribute to "intensity minutes". The current
allow-set (`MonitoringFITParser.swift:200`) is:

```
intensityActivityTypes = {1, 2, 4, 5, 6}
   = {running, cycling, fitness_equipment, swimming, walking}
```

`activity_type = 0 (generic)` is the default when field 5 is absent, and it is also used
for sleep periods and unclassified intervals. Counting it as intensity caused inflated
step/intensity totals; commit `1394778` excluded it.

Source: FIT SDK + live Instinct Solar captures.

## Message 140 — `monitoring_hr`

Heart-rate sample (HarryOnline overlay).

| Field # | Name        | Type   | Units | Notes                |
|--------:|-------------|--------|-------|----------------------|
| 253     | timestamp   | uint32 | s     | —                    |
| 1       | heart_rate  | uint8  | bpm   | bpm > 0 required (filter) |

Source: HarryOnline; confirmed live.

## Message 162 — `timestamp_correlation`

Anchors the file's clocks. Generally near the start of monitoring/HSA files.

| Field # | Name              | Type   | Units | Notes                          |
|--------:|-------------------|--------|-------|--------------------------------|
| 253     | timestamp         | uint32 | s     | UTC (Garmin epoch)             |
| 3       | local_timestamp   | uint32 | s     | Local time (Garmin epoch + TZ) |

Compass does not extract the local timestamp explicitly, but msg 162's field 253 updates
the running `lastTimestamp` baseline used by the compressed-timestamp resolver — see
[`compressed-timestamps.md`](compressed-timestamps.md).

Source: FIT SDK.

## Message 227 — `stress_level`

Standard FIT stress message. **Note:** msg 227 uses field **1** (`stress_level_time`,
uint32, Garmin epoch) as the timestamp rather than field 253. Compass falls back to field
253 if field 1 is absent (`MonitoringFITParser.swift:260-271`).

| Field # | Name              | Type   | Units | Notes                       |
|--------:|-------------------|--------|-------|-----------------------------|
| 0       | stress_level_value| uint8  | 0–100 | filter to 0..100 valid range|
| 1       | stress_level_time | uint32 | s     | Timestamp (NOT field 253)   |

Source: FIT SDK.

## Message 233 — `monitoring_v2`

> **Status:** field dump only. The HarryOnline overlay's field map is provisional and not
> confirmed against any current Compass file capture.

Likely a newer consolidated monitoring record. HarryOnline's spreadsheet lists:

| Field # | Name              | Type   | Units    | Notes |
|--------:|-------------------|--------|----------|-------|
| 253     | timestamp         | uint32 | s        | from HarryOnline |
| 0       | heart_rate        | uint8  | bpm      | from HarryOnline; 0 = blank |
| 1       | activity_type     | enum   | —        | from HarryOnline; same enum as msg 55 field 5 |
| 2       | intensity         | uint8  | —        | from HarryOnline; observed as 4-byte data on Instinct Solar |
| 3       | steps             | uint32 | steps    | from HarryOnline |
| 4       | active_calories   | uint16 | kcal     | from HarryOnline |

### Instinct Solar 1G fw 19.1 divergence

In live captures from this firmware, msg 233 records contain **only `field[2]` as a 4-byte
`data` blob** — no field 253 in the definition, no other fields. The decoder therefore
emits these records with `fields[253] == nil` (no timestamp synthesis, since the record
header was a normal data-message header, not a compressed-timestamp header). The current
parser logs a hex field dump at INFO level (`MonitoringFITParser.swift:149-159`).

Real per-second health data on this firmware lives in the HSA family (msgs 306–308, 314)
inside subtype-58 files, not in the subtype-32 file's msg 233. See
[`compressed-timestamps.md`](compressed-timestamps.md) §5 and
[`../instinct/device-reference.md`](../instinct/device-reference.md).

Source: HarryOnline + live capture (partial).

## Message 297 — `respiration_rate`

| Field # | Name             | Type   | Units       | Notes |
|--------:|------------------|--------|-------------|-------|
| 253     | timestamp        | uint32 | s           | —     |
| 0       | respiration_rate | uint8  | breaths/min | rate > 0 required |

Source: FIT SDK.

## Message 318 — `hsa_unknown_318`

> **Status: undocumented.** Not present in Garmin FIT SDK `profile.py`, Gadgetbridge, or
> the HarryOnline spreadsheet. Compass field-dumps msg 318 records at INFO level
> (`MonitoringFITParser.swift:161-170`).

Observations from Instinct Solar 1G captures:

- Appears in every subtype-58 (`monitorHealth`) file
- ~659 instances across 10 files in a single sync (~66 per file)
- At minimum carries field 253 (timestamp); other fields TBD

Hypotheses (unconfirmed): per-minute aggregated health snapshot, proprietary "health epoch"
combining multiple metrics, or an index/header for the HSA session.

Source: live Instinct Solar capture only; field map not yet known.

---

# 3. HSA family (Health Snapshot Archive)

**Source: Garmin FIT Python SDK `profile.py`** (official, not reverse-engineered).

All HSA messages share a common shape:

- **Field 253**: timestamp (start of the interval window)
- **Field 0**: `processing_interval` (uint16, seconds) — length of the array fields
- **Fields 1+**: array fields, one element per second of the interval

Element `[i]` of the array is at `timestamp + i` seconds. Compass parsers loop these arrays
to emit per-second samples (`MonitoringFITParser.swift:319-380`).

## Message 306 — `hsa_stress_data`

| Field # | Name                  | Type        | Units | Notes |
|--------:|-----------------------|-------------|-------|-------|
| 253     | timestamp             | uint32      | s     | Start of interval |
| 0       | processing_interval   | uint16      | s     | Length of array fields |
| 1       | stress_level          | sint8[]     | —     | 0–100 valid; negatives are sentinels |

`stress_level` sentinels:

| Value | Meaning                       |
|------:|-------------------------------|
| -1    | off_wrist                     |
| -2    | excess_motion                 |
| -3    | insufficient_data             |
| -4    | recovering_from_exercise      |
| -5    | unidentified                  |
| -16   | blank (no measurement this s) |

Parser filters out all negative values (`MonitoringFITParser.swift:341-342`).

Source: FIT SDK.

## Message 307 — `hsa_respiration_data`

| Field # | Name                  | Type      | Units       | Notes |
|--------:|-----------------------|-----------|-------------|-------|
| 253     | timestamp             | uint32    | s           | —     |
| 0       | processing_interval   | uint16    | s           | —     |
| 1       | respiration_rate      | uint8[]   | breaths/min | 0=blank, 255=invalid |

Source: FIT SDK.

## Message 308 — `hsa_heart_rate_data`

| Field # | Name                  | Type      | Units | Notes |
|--------:|-----------------------|-----------|-------|-------|
| 253     | timestamp             | uint32    | s     | —     |
| 0       | processing_interval   | uint16    | s     | —     |
| 1       | status                | uint8     | —     | 0=searching, 1=locked |
| 2       | heart_rate            | uint8[]   | bpm   | 0=blank, 255=invalid |

Source: FIT SDK.

## Message 314 — `hsa_body_battery_data`

| Field # | Name                  | Type        | Units | Notes |
|--------:|-----------------------|-------------|-------|-------|
| 253     | timestamp             | uint32      | s     | —     |
| 0       | processing_interval   | uint16      | s     | —     |
| 1       | level                 | sint8[]     | %     | 0–100 valid; -16=blank |
| 2       | charged               | sint16[]    | —     | Delta charged within window |
| 3       | uncharged             | sint16[]    | —     | Delta drained within window |

Compass currently extracts only `level`; `charged` and `uncharged` deltas are read off the
wire but not yet propagated (`MonitoringFITParser.swift:368-380`).

Source: FIT SDK.

### Array field encoding

HSA array fields use FIT base type `byte` (`0x0D`), so the decoder produces
`FITFieldValue.data([UInt8])`. Parsers reinterpret the bytes via the helper accessors:

```swift
fields[2]?.uint8Array   // hr, respiration
fields[1]?.int8Array    // stress, body battery (sentinel-aware sint8)
```

Defined at `FITDecoder.swift:105-122`.

---

# 4. Sleep messages

Source: `Packages/CompassFIT/Sources/CompassFIT/Parsers/SleepFITParser.swift`.

## Message 273 — `sleep_data_info`

Session header. One per sleep session.

| Field # | Name              | Type   | Units | Notes                                                      |
|--------:|-------------------|--------|-------|------------------------------------------------------------|
| 253     | timestamp         | uint32 | s     | **Sleep start time** (FIT convention)                      |
| 0       | sleep_quality     | enum   | —     | Quality category 0=poor 1=fair 2=good 3=excellent (NOT the score) |
| 1       | sleep_score       | uint16 | 0–100 | Overall sleep score                                        |
| 2       | end_time          | uint32 | s     | Sleep session end                                          |

> **Bug fix `75d3efd` — Sleep parser field mapping for Instinct Solar 1G.**
> The HarryOnline spreadsheet originally listed field 0 as `sleep_score` and fields 2/3 as
> `start_time`/`end_time`. Live Instinct Solar 1G captures showed the opposite: field 253
> is the start, field 2 is the end, field 1 is the numeric score (60 in the captured
> file), and field 0 is a 2-bit quality enum. The parser was corrected accordingly
> (`SleepFITParser.swift:86-89`).

Source: HarryOnline (originally), corrected against Instinct Solar 1G live capture.

## Message 274 — `sleep_level`

Standard form: minute-resolution sleep level samples. One record per minute.

| Field # | Name                              | Type  | Units | Notes |
|--------:|-----------------------------------|-------|-------|-------|
| 253     | timestamp                         | uint32| s     | One record per minute |
| 0       | current_activity_type_intensity   | uint8 | —     | 0=unmeasurable 1=awake 2=light 3=deep 4=REM |

Compass collapses consecutive same-level samples into stage spans
(`SleepFITParser.swift:256-282`). Level 0 (unmeasurable) is dropped.

### Instinct Solar 1G fw 19.1 divergence

On this firmware, msg 274 appears with a non-standard definition: **no field 253 and field
0 as a 20-byte `bytes` blob**. Six such records were observed for a 120-minute session,
suggesting one byte per minute packed in batches of 20. The byte values do not match the
expected 0–4 sleep-level encoding, and the encoding is unknown.

The parser falls through gracefully: `parseSleepLevel` requires both field 253 and an
integer field 0, and returns nil otherwise (`SleepFITParser.swift:172-178`). When msg 274
yields no level samples, session bounds and stages fall back to msg 273 and msg 275
respectively.

See [`../instinct/device-reference.md`](../instinct/device-reference.md).

Source: HarryOnline (standard) + live capture (Instinct Solar divergence).

## Message 275 — `sleep_stage`

Per-stage records (start of each stage).

| Field # | Name      | Type   | Units | Notes |
|--------:|-----------|--------|-------|-------|
| 253     | timestamp | uint32 | s     | Start of stage |
| 0       | stage     | enum   | —     | 0=deep 1=light 2=REM 3=awake |
| 1       | duration  | uint32 | s     | **Absent on Instinct Solar 1G** — span derived from next record's timestamp |

When duration is absent, the stage extends to the next stage's start, or the session's end
for the last stage (`SleepFITParser.swift:228-242`).

Source: HarryOnline.

## Message 276 — `sleep_assessment`

Overall quality breakdown. One record per session.

| Field # | Name                       | Type  | Units | Notes |
|--------:|----------------------------|-------|-------|-------|
| 253     | timestamp                  | uint32| s     | from HarryOnline |
| 0       | combined_awake_score       | uint8 | —     | from HarryOnline |
| 1       | awake_time_score           | uint8 | —     | from HarryOnline |
| 2       | awakenings_count_score     | uint8 | —     | from HarryOnline |
| 3       | deep_sleep_score           | uint8 | —     | from HarryOnline |
| 4       | sleep_duration_score       | uint8 | —     | from HarryOnline |
| 5       | light_sleep_score          | uint8 | —     | from HarryOnline |
| 6       | overall_sleep_score        | uint8 | —     | from HarryOnline |
| 7       | sleep_quality_score        | uint8 | —     | from HarryOnline |
| 8       | sleep_recovery_score       | uint8 | —     | from HarryOnline |
| 9       | rem_sleep_score            | uint8 | —     | from HarryOnline |
| 10      | sleep_restlessness_score   | uint8 | —     | from HarryOnline |
| 11      | awakenings_count           | uint8 | —     | from HarryOnline |

> **Status:** field dump only. The parser logs each field at debug level
> (`SleepFITParser.swift:135-139`); full decode pending confirmation against an Instinct
> Solar capture.

Source: HarryOnline; not yet confirmed against Compass live captures.

## Message 382 — `sleep_restless_moments`

| Field # | Name      | Type   | Units | Notes |
|--------:|-----------|--------|-------|-------|
| 253     | timestamp | uint32 | s     | from HarryOnline |
| 0       | duration  | uint16 | s     | from HarryOnline |

Compass currently logs occurrences but does not surface restless-moment data
(`SleepFITParser.swift:141-143`).

Source: HarryOnline; not yet confirmed against Instinct Solar captures.

## Message 412 — `nap`

| Field # | Name        | Type   | Units | Notes |
|--------:|-------------|--------|-------|-------|
| 253     | timestamp   | uint32 | s     | from HarryOnline |
| 0       | duration    | uint32 | s     | from HarryOnline |
| 1       | start_time  | uint32 | s     | from HarryOnline |
| 2       | end_time    | uint32 | s     | from HarryOnline |

Compass does not currently parse msg 412 (no nap pipeline). The field-name overlay
declares it for future use.

Source: HarryOnline; not yet seen in Instinct Solar captures.

---

# 5. Metrics messages

Source: `Packages/CompassFIT/Sources/CompassFIT/Parsers/MetricsFITParser.swift`.

## Message 78 — `hrv` (referenced)

Standard FIT HRV message containing R-R intervals.

| Field # | Name      | Type    | Units | Notes |
|--------:|-----------|---------|-------|-------|
| 253     | timestamp | uint32  | s     | May inherit from preceding timestamp message |
| 0       | time      | uint16  | ms    | R-R interval; 0xFFFF = invalid               |

Compass exposes the value as RMSSD-equivalent for now (`MetricsFITParser.swift:96-103`).
Field 0 may carry an array; current decoder treats single values.

Source: FIT SDK.

## Message 346 — `body_battery`

Per-sample Body Battery levels in `/GARMIN/Monitor/*.fit` (HarryOnline overlay).

| Field # | Name       | Type   | Units | Notes |
|--------:|------------|--------|-------|-------|
| 253     | timestamp  | uint32 | s     | —     |
| 0       | level      | uint8  | 0–100 | —     |
| 1       | charged    | sint8  | —     | Delta charged since last sample |
| 2       | drained    | sint8  | —     | Delta drained since last sample |

Source: HarryOnline; parser at `MonitoringFITParser.swift:250-258`.

## Message 369 — `training_readiness`

| Field # | Name             | Type   | Units | Notes |
|--------:|------------------|--------|-------|-------|
| 253     | timestamp        | uint32 | s     | from HarryOnline |
| 0       | readiness_score  | uint8  | 0–100 | from HarryOnline; not yet seen in Instinct Solar captures |

Source: HarryOnline; placeholder. Compass does not parse msg 369 today.

## Message 370 — `hrv_status_summary`

Garmin-specific HRV status summary.

| Field # | Name                  | Type   | Units | Notes |
|--------:|-----------------------|--------|-------|-------|
| 253     | timestamp             | uint32 | s     | —     |
| 0       | weekly_average        | float  | —     | from MetricsFITParser |
| 1       | last_night_average    | float  | —     | from MetricsFITParser |
| 2       | last_night_5min_high  | float  | —     | from MetricsFITParser |
| 3       | rmssd                 | float  | ms    | extracted by parser   |

Compass extracts field 3 directly as RMSSD (`MetricsFITParser.swift:67-72`). Other fields
are present in the parser's constants table but not yet surfaced.

Source: Garmin (proprietary); parser inference.

---

# 6. Course encoding (`CourseFITEncoder`)

Compass produces course FIT files for upload to the watch via GFDI. Source:
`Packages/CompassFIT/Sources/CompassFIT/Encoders/CourseFITEncoder.swift`.

A course file consists of (in order):

1. **`file_id` (msg 0)** — `type=COURSE (6)`, `manufacturer=255 (development)`,
   `product=0`, `serial_number=0`, `time_created=now`. Definition+data at
   `CourseFITEncoder.swift:182-215`.
2. **`course` (msg 31)** — sport + name. Definition+data at lines 217-241.
3. **`lap` (msg 19)** — single lap covering the whole course. Lines 243-300.
4. **`record` (msg 20)** — one per waypoint along the route. Lines 302-348. Definition is
   emitted only for the first record (`isFirst`); subsequent records reuse local type 3.
5. **`course_point` (msg 32)** — one per named POI / track point with a name.
   Lines 350-402.

## Message 0 — `file_id`

| Field # | Name           | Type    | Units | Notes |
|--------:|----------------|---------|-------|-------|
| 0       | type           | enum    | —     | Compass writes `6` (course)        |
| 1       | manufacturer   | uint16  | —     | Compass writes `255` (development) |
| 2       | product        | uint16  | —     | Compass writes `0`                 |
| 3       | serial_number  | uint32z | —     | Compass writes `0` (invalid OK for development manufacturer) |
| 4       | time_created   | uint32  | s     | Garmin epoch                       |

## Message 31 — `course`

| Field # | Name          | Type     | Units | Notes |
|--------:|---------------|----------|-------|-------|
| 4       | sport         | enum     | —     | Same enum as msg 18 field 5 |
| 5       | name          | string   | —     | Fixed-size 16-byte field (UTF-8, null-padded) |
| 6       | capabilities  | uint32z  | —     | Not emitted by Compass |

`course.name` is truncated to 15 ASCII chars + null terminator
(`CourseFITEncoder.swift:217-241`).

## Message 32 — `course_point`

> **Caveat:** course_point uses an unusual field-numbering scheme — `timestamp` is field
> **1** (NOT 253), and `name` is field **6** (NOT 4). Verified against the FIT SDK
> bundled in `fitparse`. (Source comment: `CourseFITEncoder.swift:351-355`.)

| Field # | Name           | Type   | Units | Notes |
|--------:|----------------|--------|-------|-------|
| 254     | message_index  | uint16 | —     | Required for the watch to enumerate POIs |
| 1       | timestamp      | uint32 | s     | Garmin epoch |
| 2       | position_lat   | sint32 | semic | — |
| 3       | position_long  | sint32 | semic | — |
| 4       | distance       | uint32 | cm    | Scale 100 |
| 5       | type           | enum   | —     | 0=generic 1=summit 2=valley 3=water 4=food 5=danger 6=left 7=right 8=straight 9=first_aid … |
| 6       | name           | string | —     | 16-byte fixed-size UTF-8 |

Course points are sorted by `distanceFromStart` so message_index is monotonic
(`CourseFITEncoder.swift:136-138`).

## Pacing strategy

When the source GPX has `<time>` elements on track points, Compass uses the recorded
timestamps directly for record messages, giving the watch's virtual partner real pace
variation (slow on climbs, fast on descents). When timestamps are absent but
`estimatedDuration > 0`, Compass distributes time linearly along the cumulative distance.
When neither is available, every record gets `baseTime` (no pacing data — watch shows no
ETA). See `CourseFITEncoder.swift:74-106`.

The lap's `total_elapsed_time` is derived from `endTime - baseTime` so both pacing paths
emit the right value without extra arguments. The FIT invalid sentinel `0xFFFFFFFF` is
written when no timing data is available (`CourseFITEncoder.swift:293-294`).

Source: FIT SDK; semantics empirically verified against `fitparse`.

---

# 7. Field-name overlay

The runtime overlay in `harry_overlay.json` (loaded via
`Packages/CompassFIT/Sources/CompassFIT/Overlay/FieldNameOverlay.swift`) provides
human-readable names for messages 21, 140, 162, 211, 233, 273-276, 306-308, 314, 318,
346, 369, 382, 412. It is consulted by parsers when an unknown message is encountered to
log a useful debug name (`ActivityFITParser.swift:81-85`,
`SleepFITParser.swift:144-148`, `MonitoringFITParser.swift:172-177`,
`MetricsFITParser.swift:74-83`).

Coverage and confidence:

| Msg # | Name                     | Source                              | Status                  |
|------:|--------------------------|-------------------------------------|-------------------------|
| 21    | event                    | FIT SDK                             | Standard; overlay only  |
| 140   | monitoring_hr            | HarryOnline                         | Confirmed; parsed       |
| 162   | timestamp_correlation    | FIT SDK                             | Standard; overlay only  |
| 211   | monitoring_info          | HarryOnline                         | Placeholder             |
| 233   | monitoring_v2            | HarryOnline + live capture          | Field dump only         |
| 273   | sleep_data_info          | HarryOnline → corrected via live    | Parsed (post-`75d3efd`) |
| 274   | sleep_level              | HarryOnline + live capture          | Parsed (standard form)  |
| 275   | sleep_stage              | HarryOnline                         | Parsed (fallback path)  |
| 276   | sleep_assessment         | HarryOnline                         | Field dump only         |
| 306   | hsa_stress_data          | Garmin FIT Python SDK               | Parsed                  |
| 307   | hsa_respiration_data     | Garmin FIT Python SDK               | Parsed                  |
| 308   | hsa_heart_rate_data      | Garmin FIT Python SDK               | Parsed                  |
| 314   | hsa_body_battery_data    | Garmin FIT Python SDK               | Parsed (level only)     |
| 318   | hsa_unknown_318          | none (undocumented)                 | Field dump only         |
| 346   | body_battery             | HarryOnline                         | Parsed                  |
| 369   | training_readiness       | HarryOnline                         | Placeholder             |
| 382   | sleep_restless_moments   | HarryOnline                         | Placeholder             |
| 412   | nap                      | HarryOnline                         | Placeholder             |

---

## Source

- `Packages/CompassFIT/Sources/CompassFIT/Parsers/ActivityFITParser.swift`
  (msgs 18, 19, 20, 23, 34)
- `Packages/CompassFIT/Sources/CompassFIT/Parsers/MonitoringFITParser.swift`
  (msgs 55, 140, 162, 227, 233, 297, 306, 307, 308, 314, 318, 346)
- `Packages/CompassFIT/Sources/CompassFIT/Parsers/SleepFITParser.swift`
  (msgs 273, 274, 275, 276, 382)
- `Packages/CompassFIT/Sources/CompassFIT/Parsers/MetricsFITParser.swift`
  (msgs 78, 370)
- `Packages/CompassFIT/Sources/CompassFIT/Encoders/CourseFITEncoder.swift`
  (msgs 0, 19, 20, 31, 32)
- `Packages/CompassFIT/Sources/CompassFIT/Resources/harry_overlay.json` — overlay JSON
- `Packages/CompassFIT/Sources/CompassFIT/Overlay/FieldNameOverlay.swift` — overlay loader

External:
- Garmin FIT SDK `profile.py` — official msgs 0, 18-23, 34, 55, 78, 162, 227, 297, 306, 307, 308, 314
- HarryOnline Garmin FIT extensions spreadsheet — msgs 140, 211, 233, 273-276, 346, 369, 382, 412
- Gadgetbridge `app/src/main/java/.../service/devices/garmin/fit/{FieldDefinition,FileType,RecordHeader}.java`

Cross-references:
- [`format.md`](format.md) — FIT wire format
- [`compressed-timestamps.md`](compressed-timestamps.md) — compressed-timestamp resolver
- [`../instinct/device-reference.md`](../instinct/device-reference.md) — Instinct Solar 1G
  device-specific quirks (sleep, HR, stress field maps)

Notable bug fixes:
- Commit `1394778` — Fix active minutes counting sleep / generic intervals as intensity
  (msg 55 field 5 enum filter at `MonitoringFITParser.swift:200`).
- Commit `75d3efd` — Fix sleep parser field mapping for Instinct Solar 1G
  (msg 273 fields 0/1/2/253 swap; `SleepFITParser.swift:86-89`).

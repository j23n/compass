# Garmin FIT Message Types — Research Reference

_Written: 2026-04-29 — based on Garmin FIT Python SDK `profile.py`, Gadgetbridge source,
HarryOnline spreadsheet, and live captures from an Instinct Solar 1G._

This document records findings about Garmin-proprietary and poorly-documented FIT message
numbers that appear in health-data files synced from the Instinct Solar. It complements the
standard Garmin FIT SDK (which covers messages 0–227 in the public profile) and is the
reference for the parsers in `CompassFIT`.

---

## Table of Contents

1. [File Subtypes — Health Data Files](#1-file-subtypes--health-data-files)
2. [Compressed Timestamps (FIT §3.3.7)](#2-compressed-timestamps-fit-337)
3. [Standard Messages Used in Health Files](#3-standard-messages-used-in-health-files)
4. [HSA Message Family (msgs 306–314)](#4-hsa-message-family-msgs-306314)
5. [Message 233 — monitoring_v2](#5-message-233--monitoring_v2)
6. [Message 318 — hsa_unknown_318](#6-message-318--hsa_unknown_318)
7. [Sleep Messages (msgs 273–276, 382, 412)](#7-sleep-messages-msgs-273276-382-412)
8. [Message 162 — timestamp_correlation](#8-message-162--timestamp_correlation)
9. [Overlay JSON Coverage](#9-overlay-json-coverage)

---

## 1. File Subtypes — Health Data Files

Garmin watches expose files via the GFDI directory listing as `(dataType, subType)` pairs.
All FIT files have `dataType = 128 (0x80)`. The `subType` determines the file's content class.

### Subtypes relevant to health data

| dataType/subType | Symbol in Compass | Gadgetbridge symbol | Content |
|---|---|---|---|
| 128/4  | `activity`      | `ACTIVITY`   | Activity recording (run, ride, etc.) |
| 128/32 | `monitor`       | `MONITOR`    | Daily monitoring envelope (msg 55, sometimes msg 233) |
| 128/44 | `metrics`       | `METRICS`    | Aggregate health metrics summaries |
| 128/49 | `sleep`         | `SLEEP`      | Sleep sessions (msgs 273–276, 382) |
| 128/58 | `monitorHealth` | `DEVICE_58`  | HSA archive — **primary health data on Instinct Solar** |
| 128/70 | _(not yet seen)_ | `HSA`       | HSA on other firmware variants |

### Subtype 58 — `monitorHealth` — Key Finding

On the Instinct Solar 1G, subtype **58** files (not subtype 32 or 70) contain all the
per-second health timeseries: heart rate, stress, respiration, and body battery. These are
**HSA (Health Snapshot Archive) files**.

A typical Instinct Solar sync produces:
- **1** subtype-32 file: thin envelope with msg 233 records (timestamp + 4 B payload)
- **10–12** subtype-58 files: one per session, each containing msgs 306–314 with
  per-second arrays and msg 318

Before subtype 58 was added to `FileType` (see `FileMetadata.swift`), all health data was
silently skipped — zero HR, stress, BB, and respiration despite hours of data on the watch.

Gadgetbridge calls subtype 58 `DEVICE_58` and describes it as "Device on Fenix 7s"; the
naming is misleading. On the Instinct Solar 1G it is an HSA-format file. We call it
`monitorHealth` in Compass.

---

## 2. Compressed Timestamps (FIT §3.3.7)

Many monitoring and HSA messages do not carry an explicit timestamp field (253). Instead,
the FIT record header uses bit 7 (`0x80`) to indicate a **compressed timestamp**: the
header byte encodes a 5-bit offset from a "rolling" baseline:

```
record_header byte:
  bit 7     = 1          (compressed timestamp flag)
  bits 6–5  = local msg number (0–3)
  bits 4–0  = 5-bit time offset (seconds, 0–31)
```

Resolution rule (FIT SDK §3.3.7):

```
timeOffset = header & 0x1F
if timeOffset >= (lastTimestamp & 0x1F):
    timestamp = (lastTimestamp & ~0x1F) | timeOffset
else:
    timestamp = ((lastTimestamp & ~0x1F) + 32) | timeOffset
```

The `FITDecoder` synthesises a virtual field 253 (Garmin-epoch `uint32`) and injects it
into compressed-timestamp messages so that parsers can read `fields[253]` uniformly.

**Important:** msg 233 in subtype-32 files does *not* use compressed timestamps — it
carries a normal (non-compressed) record header but omits field 253 from its definition.
These records genuinely have no per-record timestamp; the file's timestamps come from
surrounding non-compressed messages.

---

## 3. Standard Messages Used in Health Files

These are in the official Garmin FIT SDK profile; listed here for quick reference.

### Message 55 — `monitoring`

The standard per-minute step/activity record. Appears in subtype-32 `monitor` files.

| Field | Name | Type | Notes |
|---|---|---|---|
| 253 | timestamp | date_time | Garmin epoch uint32; may be injected from compressed ts |
| 2 | cycles | uint32 | Cumulative cycles since midnight per FIT SDK; **always 0 on Instinct Solar fw 19.1** — field 3 carries the step count instead |
| 3 | steps / active_time | uint32 | FIT subfield: when activity_type = walking (6) or running (1), raw cumulative step count since midnight (**no ×2 scaling** on Instinct Solar); otherwise active_time in ms (scale 1000, seconds) |
| 4 | active_calories | uint16 | kcal |
| 5 | activity_type | enum | 0=generic, 1=running, 2=cycling, 3=transition, 4=fitness_equipment, 5=swimming, 6=walking, **8=sedentary** (NOT 7 on Instinct Solar — confirmed from USB FIT dump), 254=invalid |

**Compact HR variant (field 27):** Some firmware builds (e.g. Instinct 2 Solar Surf) embed
heart rate directly in msg 55 using field 26 (`timestamp_16`, lower 16 bits of Garmin epoch)
and field 27 (`heart_rate`, uint8 bpm). The parser handles this variant transparently.

### Message 18 — `session`

Summary record at end of each activity FIT file.

| Field | Name | Type | Notes |
|---|---|---|---|
| 253 | timestamp | date_time | — |
| 2 | start_time | date_time | — |
| 5 | sport | enum | 0=generic, 1=running, 2=cycling, … |
| 7 | total_elapsed_time | uint32 | Scale 1000; seconds |
| 9 | total_distance | uint32 | Scale 100; metres — **field 9, not 5** |
| 11 | total_calories | uint16 | kcal |
| 16 | avg_heart_rate | uint8 | bpm |
| 17 | max_heart_rate | uint8 | bpm |
| 22 | total_ascent | uint16 | metres |
| 23 | total_descent | uint16 | metres |

---

## 4. HSA Message Family (msgs 306–314)

**Source:** Garmin FIT Python SDK `profile.py` (official SDK, not reverse-engineered).

HSA = Health Snapshot Archive. All HSA messages share a common structure:

- **Field 253**: timestamp (date_time, Garmin epoch) — marks the *start* of the interval
- **Field 0**: `processing_interval` (uint16, seconds) — the duration of the data window
- **Fields 1+**: array fields — one element per second of the interval; element [i] covers
  `timestamp + i` seconds

### Message 306 — `hsa_stress_data`

| Field | Name | Type | Units | Notes |
|---|---|---|---|---|
| 253 | timestamp | date_time | s | Start of interval |
| 0 | processing_interval | uint16 | s | Length of array fields |
| 1 | stress_level | **sint8[]** | — | 0–100 = valid stress; negatives = error codes (see below) |

**`stress_level` sentinel values:**
- `-1` = off_wrist
- `-2` = excess_motion
- `-3` = insufficient_data
- `-4` = recovering_from_exercise
- `-5` = unidentified
- `-16` = blank (no measurement in this second)

### Message 307 — `hsa_respiration_data`

| Field | Name | Type | Units | Notes |
|---|---|---|---|---|
| 253 | timestamp | date_time | s | — |
| 0 | processing_interval | uint16 | s | — |
| 1 | respiration_rate | **uint8[]** | breaths/min | 0=blank, 255=invalid |

### Message 308 — `hsa_heart_rate_data`

| Field | Name | Type | Units | Notes |
|---|---|---|---|---|
| 253 | timestamp | date_time | s | — |
| 0 | processing_interval | uint16 | s | — |
| 1 | status | uint8 | — | 0=searching, 1=locked |
| 2 | heart_rate | **uint8[]** | bpm | 0=blank, 255=invalid |

### Message 314 — `hsa_body_battery_data`

| Field | Name | Type | Units | Notes |
|---|---|---|---|---|
| 253 | timestamp | date_time | s | — |
| 0 | processing_interval | uint16 | s | — |
| 1 | level | **sint8[]** | % | 0–100 valid; -16=blank |
| 2 | charged | sint16[] | — | Delta charged in interval |
| 3 | uncharged | sint16[] | — | Delta drained in interval |

### Array field encoding

HSA array fields are stored as a FIT `byte[]` (`base_type = 0x0D`). The `FITDecoder` parses
them into `FITFieldValue.data([UInt8])`. Access via:

```swift
fields[2]?.uint8Array   // heart_rate, respiration_rate
fields[1]?.int8Array    // stress_level, body_battery level
```

The `uint8Array` and `int8Array` computed properties on `FITFieldValue` reinterpret the
raw `Data` bytes as typed arrays.

---

## 5. Message 233 — `monitoring_v2`

**Source:** HarryOnline spreadsheet; partially confirmed from Instinct Solar 1G captures.

Appears in subtype-32 `monitor` files. Likely a newer consolidated monitoring record that
replaces or supplements msg 55 on current firmware.

| Field | Name | Type | Units | Notes |
|---|---|---|---|---|
| 253 | timestamp | date_time | s | — |
| 0 | heart_rate | uint8 | bpm | Confirmed presence (0=blank) |
| 1 | activity_type | enum | — | Same enum as msg 55 field 5 |
| 2 | intensity | uint8 | — | Observed as 4B data; exact scale unclear |
| 3 | steps | uint32 | steps | — |
| 4 | active_calories | uint16 | kcal | — |

### Instinct Solar observation

On the Instinct Solar 1G, msg 233 records contain only `field[2] = data(4 bytes)` — all
other fields are absent in the field definition used by this watch. This means the subtype-32
file carries very limited data. **The real per-second health data is in the subtype-58 HSA files.**

Current parser: field dump only (logged at INFO level with hex). Full decode pending
confirmation of field values from a subtype-32 file with more populated fields.

---

## 6. Message 318 — `hsa_unknown_318`

**Status: Undocumented.** Not present in:
- Garmin FIT Python SDK `profile.py`
- Gadgetbridge source
- HarryOnline spreadsheet

### What we know

- Appears in every subtype-58 file on the Instinct Solar 1G
- Observed ~659 instances across 10 files in a single sync
- Filed under the `hsa_*` naming convention in our overlay as `hsa_unknown_318`
- Contains at minimum a timestamp (field 253); other fields pending the field dump

### Field dump

The current parser logs all fields of msg 318 at INFO level:

```
MSG318 field[N] = <value>
```

Check console logs after the next sync to determine the field structure. Once confirmed,
implement a decoder and update `harry_overlay.json`.

### Hypothesis

Given the density (659 instances / 10 files ≈ 66 per file), msg 318 may be:
- A per-minute or per-5-minute aggregated health snapshot
- A proprietary "health epoch" record combining multiple metrics
- An index/header record for the HSA session

---

## 7. Sleep Messages (msgs 273–276, 382, 412)

Sleep files (subtype 49) use a different set of messages from monitoring files.

### Message 273 — `sleep_data_info`

Session-level header. One per sleep session.

| Field | Name | Type | Notes |
|---|---|---|---|
| 253 | timestamp | date_time | **Sleep start time** (FIT convention: timestamp = start of the record's interval) |
| 0 | sleep_quality | enum | Quality category: 0=poor, 1=fair, 2=good, 3=excellent — **not the numeric score** |
| 1 | sleep_score | uint16 | Overall sleep score 0–100 |
| 2 | end_time | date_time | Sleep session end time |

**Correction vs. earlier notes:** The HarryOnline spreadsheet listed field 0 as `sleep_score` and fields 2/3 as start/end times. Live Instinct Solar 1G captures show the opposite: field 253 (timestamp) is the start, field 2 is the end, field 1 is the numeric score (60 in the captured file), and field 0 is a 2-bit quality enum. The parser was fixed accordingly.

### Message 274 — `sleep_level`

**On Instinct Solar 1G (live capture 2026-04-30):** message 274 appears with a non-standard definition — no timestamp field (253) and field 0 as a 20-byte blob (`bytes` type). Six such records were present for a 120-minute session, suggesting one byte per minute packed in batches of 20.

The byte values in the blob do not match the expected 0–4 sleep level encoding; the encoding is unknown. The parser currently skips these records gracefully (returns nil from `parseSleepLevel` when field 253 or an integer field 0 is absent). Session bounds and stages fall back to msg 273 and msg 275 respectively.

**Standard definition (other firmware):** One record per minute; stage from field 0.

| Field | Name | Type | Notes |
|---|---|---|---|
| 253 | timestamp | date_time | One record per minute |
| 0 | current_activity_type_intensity | uint8 | 0=unmeasurable, 1=awake, 2=light, 3=deep, 4=REM |

Stage mapping for `SleepStage` persistence:
- 0 → skip (unmeasurable)
- 1 → `.awake`
- 2 → `.light`
- 3 → `.deep`
- 4 → `.rem`

### Message 275 — `sleep_stage`

| Field | Name | Type | Notes |
|---|---|---|---|
| 253 | timestamp | date_time | Start of the stage |
| 0 | stage | enum | 0=deep, 1=light, 2=REM, 3=awake |
| 1 | duration | uint32 | seconds — **absent on Instinct Solar 1G** |

**Observed on Instinct Solar 1G** — contrary to earlier notes. However, field 1 (duration) is absent. The parser derives stage spans from consecutive record timestamps; the last stage extends to the session end.

### Message 276 — `sleep_assessment`

Overall quality breakdown. One record per sleep session.

| Field | Name | Type | Notes |
|---|---|---|---|
| 253 | timestamp | date_time | — |
| 0 | combined_awake_score | uint8 | — |
| 1 | awake_time_score | uint8 | — |
| 2 | awakenings_count_score | uint8 | — |
| 3 | deep_sleep_score | uint8 | — |
| 4 | sleep_duration_score | uint8 | — |
| 5 | light_sleep_score | uint8 | — |
| 6 | overall_sleep_score | uint8 | — |
| 7 | sleep_quality_score | uint8 | — |
| 8 | sleep_recovery_score | uint8 | — |
| 9 | rem_sleep_score | uint8 | — |
| 10 | sleep_restlessness_score | uint8 | — |
| 11 | awakenings_count | uint8 | — |

**Source:** HarryOnline spreadsheet (field numbers are probable; field dump is in place).
Current parser: field dump at INFO level. Full decode pending field dump confirmation.

The `recovery_score` and `qualifier` fields on `SleepSession` will be populated from this
message once the field map is confirmed.

### Message 382 — `sleep_restless_moments`

| Field | Name | Type | Notes |
|---|---|---|---|
| 253 | timestamp | date_time | — |
| 0 | duration | uint16 | seconds |

### Message 412 — `nap`

| Field | Name | Type | Notes |
|---|---|---|---|
| 253 | timestamp | date_time | — |
| 0 | duration | uint32 | seconds |
| 1 | start_time | date_time | — |
| 2 | end_time | date_time | — |

---

## 8. Message 162 — `timestamp_correlation`

Used to establish a relationship between the FIT file's internal compressed timestamps and
wall-clock time. Appears near the start of monitoring and HSA files.

| Field | Name | Type | Notes |
|---|---|---|---|
| 253 | timestamp | date_time | UTC (Garmin epoch) |
| 3 | local_timestamp | date_time | Local time (Garmin epoch + TZ offset) |

The `FITDecoder` uses field 253 from explicit `timestamp_correlation` records to reset the
running `lastTimestamp` baseline used for compressed-timestamp resolution.

---

## 9. Overlay JSON Coverage

`harry_overlay.json` provides human-readable field names for messages not in the standard
FIT SDK profile. Current coverage as of 2026-04-29:

| Msg # | Name | Source | Status |
|---|---|---|---|
| 21 | event | FIT SDK | Standard; added for completeness |
| 140 | monitoring_hr | HarryOnline | Confirmed; parsed |
| 162 | timestamp_correlation | FIT SDK | Standard; added for completeness |
| 211 | monitoring_info | HarryOnline | Placeholder |
| 233 | monitoring_v2 | HarryOnline + live capture | Field dump only |
| 273 | sleep_data_info | HarryOnline | Parsed |
| 274 | sleep_level | HarryOnline + live capture | Confirmed; parsed |
| 275 | sleep_stage | HarryOnline | Parsed (fallback path) |
| 276 | sleep_assessment | HarryOnline | Field dump only |
| 306 | hsa_stress_data | Garmin FIT Python SDK | Parsed |
| 307 | hsa_respiration_data | Garmin FIT Python SDK | Parsed |
| 308 | hsa_heart_rate_data | Garmin FIT Python SDK | Parsed |
| 314 | hsa_body_battery_data | Garmin FIT Python SDK | Parsed |
| 318 | hsa_unknown_318 | None (undocumented) | Field dump only |
| 346 | body_battery | HarryOnline | Parsed |
| 369 | training_readiness | HarryOnline | Placeholder |
| 382 | sleep_restless_moments | HarryOnline | Placeholder |
| 412 | nap | HarryOnline | Placeholder |

---

## Sources

- **Garmin FIT Python SDK** (`profile.py`): official field definitions for msgs 306–314 (HSA family)
- **HarryOnline Garmin FIT extensions spreadsheet**: community-maintained field maps for
  Garmin-proprietary messages not in the public SDK
- **Gadgetbridge** (`FileType.java`, `GarminSupport.java`): file subtype table; sync protocol
- **Live captures**: Instinct Solar 1G firmware 3.x, synced via `compass` iOS app

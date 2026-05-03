# Garmin Instinct Solar (1st gen) — Device Reference

_Based on live BLE captures and a USB FIT dump from an Instinct Solar (1st gen),
firmware 19.1, product ID 3466. Last refreshed 2026-04-30._

> **Identity note.** Some FIT-analysis tooling misidentifies product 3466 as
> "Instinct 2 Solar Surf". This is the original **Garmin Instinct Solar (1st
> gen)**. Use "Instinct Solar" when searching Gadgetbridge issues, source, or
> community resources — not "Instinct 2" or "Solar Surf".

This is the device-level companion to the protocol docs. The protocol docs
describe *how* a sync works on the wire; this one describes *what you actually
get* when you sync an Instinct Solar 1G with Compass, and the firmware quirks
that the parsers and transport layer have to work around.

---

## Table of Contents

1. [Device overview](#1-device-overview)
2. [Health features and data sources](#2-health-features-and-data-sources)
3. [FIT files produced](#3-fit-files-produced)
4. [Compass model mapping](#4-compass-model-mapping)
5. [Firmware and protocol quirks](#5-firmware-and-protocol-quirks)
6. [Related documentation](#6-related-documentation)

---

## 1. Device overview

| Property | Value |
|---|---|
| Model | Garmin Instinct Solar (1st gen) |
| Garmin product ID | 3466 |
| Firmware tested | 19.1 |
| BLE transport | Garmin V2 Multi-Link → COBS → GFDI |
| File-sync mechanism | Legacy GFDI file-sync (5002/5004/5008), **not** the protobuf `FileSyncService` |
| Epoch | Garmin epoch — seconds since 1989-12-31 00:00:00 UTC (`Unix − 631_065_600`) |

Transport-stack details live under [`../transport/`](../transport/) (GATT,
Multi-Link, COBS, CRC-16). The GFDI envelope is documented in
[`../gfdi/message-format.md`](../gfdi/message-format.md), and the catalog of
message types is in [`../gfdi/message-types.md`](../gfdi/message-types.md).

---

## 2. Health features and data sources

### Heart rate

- **Continuous 24/7 HR** — HSA files (subtype 58), msg 308 (`hsa_heart_rate_data`)
  as per-second `uint8[]` arrays.
- **Per-minute HR during monitoring** — msg 140 (`monitoring_hr`) in the
  subtype-32 daily monitor file.
- **Activity HR** — msg 20 (`record`) per-second in activity FIT files.
- **Session avg/max HR** — msg 18 (`session`), fields 16/17.

### Steps and activity

- **Per-minute monitoring intervals** — msg 55 (`monitoring`) in the subtype-32
  monitor file (cycles, active_time, active_calories, activity_type).
- **Consolidated v2 records** — msg 233 (`monitoring_v2`) also appears in the
  subtype-32 file but on this firmware carries only `field[2] = 4 bytes` of
  opaque data (see Quirks §5).

Activity-type enum (msg 55 field 5 / msg 233 field 1) as observed:

| Value | Meaning |
|------:|---------|
| 0 | generic |
| 1 | running |
| 2 | cycling |
| 3 | transition |
| 4 | fitness_equipment |
| 5 | swimming |
| 6 | walking |
| 8 | **sedentary** (NOT 7 — confirmed against USB FIT dump) |
| 254 | invalid |

Steps: field 3 of msg 55 carries the **raw cumulative step count since
midnight** when activity_type ∈ {1=running, 6=walking}. **No ×2 scaling**
applies on this firmware (field 2 / `cycles` is always 0). Per-interval delta is
`field3_current − field3_prev`, with midnight rollover handled by treating any
decrease as a reset to the new value.

### Stress

- HSA files, msg 306 (`hsa_stress_data`), field 1: `sint8[]` per-second.
  0–100 valid, negative = error/blank
  (`-1`=off_wrist, `-2`=excess_motion, `-3`=insufficient_data,
  `-4`=recovering_from_exercise, `-5`=unidentified, `-16`=blank).

### Respiration

- HSA files, msg 307 (`hsa_respiration_data`), field 1: `uint8[]` breaths/min.
  0=blank, 255=invalid.

### Body Battery

- HSA files, msg 314 (`hsa_body_battery_data`), field 1: `sint8[]` 0–100,
  `-16`=blank.
- Point-in-time: msg 346 (`body_battery`) — observed rarely on this device; the
  HSA stream is the primary source.

### Sleep

- **Session metadata** — msg 273 (`sleep_data_info`).
  Field map confirmed live: `field[253]` = start, `field[2]` = end,
  `field[1]` = numeric score, `field[0]` = quality enum 0–3.
- **Per-minute staging** — msg 274 (`sleep_level`).
  *Standard layout* (firmware 19.1 baseline expectation): field 0 = 1=awake,
  2=light, 3=deep, 4=REM, 0=unmeasurable. **In live captures the records arrive
  as 20-byte opaque blobs with no recognizable timestamp**, so the parser
  currently returns `nil` from msg 274 and falls back to msg 275 — see
  Quirks §5.
- **Stage entries (fallback)** — msg 275 (`sleep_stage`). Field 1 (duration) is
  omitted on this firmware; spans are derived from consecutive timestamps.
  Stage enum: 0=deep, 1=light, 2=REM, 3=awake.
- **Quality breakdown** — msg 276 (`sleep_assessment`) — currently field-dump
  only, full decode pending.
- **Restless moments** — msg 382 (`sleep_restless_moments`) — count only.

### Training readiness / HRV

- Msg 369 / 370 in metrics files (subtype 44) — field 0 = score 0–100. Parsed
  by `MetricsFITParser`.
- Subtype-68 (`HRV_STATUS`) files have not been observed from this device.

---

## 3. FIT files produced

A typical sync from an Instinct Solar 1G yields:

| Subtype | Count (typical) | Content | Compass directory |
|--------:|----------------:|---------|-------------------|
| 4 (activity)        | 0–N | One per recorded activity | `.activity` |
| 32 (monitor)        | 1   | Daily monitor envelope: msgs 55 + 233 | `.monitor`  |
| 44 (metrics)        | 1   | Aggregate summaries (training readiness) | `.metrics`  |
| 49 (sleep)          | 0–N | One per night: msgs 273–276, 382 | `.sleep`    |
| 58 (monitorHealth)  | 10–12 | HSA sessions: msgs 162, 306–308, 314, 318 | `.monitor`  |

Subtype mapping is defined in `Packages/CompassBLE/.../Sync/FileMetadata.swift`
(`FileType` enum). Parser routing per file role is summarized in
[`../fit/messages.md`](../fit/messages.md).

### Subtype 32 vs subtype 58

The subtype-32 monitor file is a lightweight "today's envelope" — a handful of
msg 55 intervals (one per significant activity-type transition) and a handful
of skeletal msg 233 records.

The **real timeseries** lives entirely in the subtype-58 (HSA, *Health Snapshot
Archive*) files. Each subtype-58 file represents one contiguous monitoring
session — typically a few hours — and carries:

```
msg 162 — timestamp_correlation (anchors session to UTC)
msg 318 — undocumented HSA record, ~66× per file (field dump only)
msg 308 — hsa_heart_rate_data    per-second HR     uint8[]
msg 306 — hsa_stress_data        per-second stress sint8[]
msg 307 — hsa_respiration_data   per-second resp   uint8[]
msg 314 — hsa_body_battery_data  per-second bb     sint8[]
```

Each HSA message has a `processing_interval` (field 0, uint16, seconds) giving
the array length. The message timestamp marks the *start* of the interval;
element `[i]` corresponds to `timestamp + i seconds`.

### File flags and archive marking

After a successful download, Compass sends `SetFileFlagsMessage(ARCHIVE = 0x10)`
(GFDI type 5008). The watch then excludes archived files from future directory
listings, so subsequent syncs skip them without redownload. See
[`../gfdi/file-sync-download.md`](../gfdi/file-sync-download.md) §1(c).

---

## 4. Compass model mapping

| Health feature      | FIT source                   | Compass model |
|---------------------|------------------------------|---------------|
| Heart rate          | msg 308 (HSA), msg 140       | `HeartRateSample` |
| Steps               | msg 55 field 3 (delta)       | `StepCount` (day aggregate) |
| Active minutes      | msg 55 field 5 allowlist     | `StepCount.intensityMinutes` |
| Active calories     | msg 55 field 4               | `MonitoringInterval.activeCalories` |
| Stress              | msg 306 (HSA)                | `StressSample` |
| Respiration         | msg 307 (HSA)                | `RespirationSample` |
| Body Battery        | msg 314 (HSA), msg 346       | `BodyBatterySample` |
| Sleep session       | msg 273                      | `SleepSession` |
| Sleep staging       | msg 275 fallback (see §5)    | `SleepStage` |
| Sleep quality       | msg 276 (pending)            | `SleepSession.recoveryScore`, `.qualifier` |
| Activity workout    | msg 18 (session)             | `Activity` |

Parsers: `MonitoringFITParser`, `SleepFITParser`, `ActivityFITParser`,
`MetricsFITParser` (all in `Packages/CompassFIT/Sources/CompassFIT/Parsers/`).

---

## 5. Firmware and protocol quirks

These are the divergences from the Gadgetbridge reference behavior that came up
during iOS implementation. Each one corresponds to a workaround in the source.

### 5.1 `DownloadRequestStatus` arrives as a full RESPONSE frame

The compact-typed status form `5002 | 0x8000` documented in some Gadgetbridge
notes is **not** what this firmware emits. The Instinct Solar 1G ACKs a 5002
`DownloadRequest` with a full `RESPONSE (0x1388)` frame whose `originalType =
5002`. The same applies to `SetFileFlagsStatus` (the ACK to 5008).

Compass therefore awaits `.response` (not the compact-typed variant) for both
messages. See [`../gfdi/file-sync-download.md`](../gfdi/file-sync-download.md)
§3 and [`../gfdi/message-format.md`](../gfdi/message-format.md) for the
RESPONSE wrapping convention.

### 5.2 `downloadStatus = 3` with `maxFileSize = 0` while still streaming

Some files return `downloadStatus = 3` (NO_SPACE_LEFT) with `maxFileSize = 0`
in their `DownloadRequestStatus`, then proceed to stream `FileTransferData`
chunks normally. The watch is *not* actually refusing the transfer.

Workaround: gate only on `outerStatus == 0` (the RESPONSE-level status, not
`downloadStatus`). When `maxFileSize = 0`, do not size-cap the buffer; instead
watch for the **last-chunk flag** `flags & 0x08` on a `FileTransferData` chunk
to detect end-of-transfer. See
[`../gfdi/file-sync-download.md`](../gfdi/file-sync-download.md) §4.

### 5.3 Subtype 58 (HSA) carries the primary timeseries

Before `monitorHealth = 58` was added to `FileType`, every subtype-58 file was
silently skipped — producing zero HR, stress, body battery and respiration in
Compass even though the watch exposed hours of data. The subtype-32 envelope
on this device contains almost nothing; the timeseries lives in subtype-58.

Fix: `FileType.monitorHealth = 58` mapped to `FITDirectory.monitor`. Routed to
`MonitoringFITParser` like subtype 32. See
[`../fit/messages.md`](../fit/messages.md) §"File roles" for the routing table.

### 5.4 Msg 233 carries minimal data on this firmware

Subtype-32 `monitoring_v2` records contain only `field[2] = 4 bytes` of opaque
data on Instinct Solar 1G. The parser logs a hex field-dump and otherwise
treats the record as a no-op; all useful health data is recovered from the
HSA (subtype-58) stream. Decode for the 4-byte payload remains TODO.

### 5.5 Msg 274 (sleep_level) — non-standard 20-byte blob

The standard `sleep_level` layout is field 253 = timestamp, field 0 = level
(1–4). On Instinct Solar 1G fw 19.1, msg 274 records arrive as a single 20-byte
opaque blob with no recognizable timestamp or level field.

**Reverse-engineered layout** (from `sleep_2026-05-02_08-48-17_57220DC8.fit`,
507 records, ~8.5 h session):

| Bytes | Interpretation |
|-------|----------------|
| 0–15  | 8 × int16 LE — accelerometer statistics (exact sub-field mapping unknown) |
| 16–17 | uint16 LE — wrist-motion metric; **0 = still, >0 = movement detected** |
| 18    | uint8 — ancillary metric (possibly HRV or confidence; values 0–254, no clear trend) |
| 19    | uint8 — **sleep stage**, offset-encoded: 81=deep, 82=light, 83=REM, 84–85=awake/arousal |

**Byte 19 (sleep stage) detail.** Values range 80–85 with a clear sleep-arc:
- 22–23 h: 82 (light — falling asleep) 
- 01–04 h: 81 (deep NREM — nadir)
- 05–06 h: 83–85 (REM / waking — rising)

One record per minute; 507 records for an ~8.5 h session (vs. 6 records in the
earlier S4UA2600.FIT file, which is a false-positive short session).

**Bytes 16–17 (motion metric) detail.** Zero during deep sleep, non-zero
during arousal events. The col-0 sign of bytes 0–15 (int16) is strongly
correlated with this field: col0 positive ↔ bytes 16–17 non-zero in 87% of
records. The 119 non-zero motion records cluster heavily in the final 2 h of
the session (05:00–06:27), consistent with increasing arousal near wake.

**Bytes 0–15 (accelerometer) detail.** Absolute magnitude per int16 column is
stable (~15 000–20 000 LSB) across all hours. Sum-of-squares √≈ 50 000 is
consistent throughout, suggesting a fixed-magnitude gravity vector that rotates
as wrist orientation changes. Sign pattern of col0 distinguishes two record
sub-types: negative (~378 records, still/asleep) and positive (~129 records,
movement/arousal).

**Practical stage inference from msg 274 alone:**

```
hr_stage  = blob[19]          # 81=deep 82=light 83=REM 84-85=awake
motion    = blob[16] | blob[17]  # 0=still >0=moving
```

- `motion > 0 AND hr_stage ≥ 83` → awake/aroused
- `motion > 0 AND hr_stage ≤ 82` → light sleep / REM
- `motion = 0 AND hr_stage = 81` → deep sleep
- `motion = 0 AND hr_stage = 82` → light sleep

This yields 507 per-minute stage estimates vs. 18 incomplete records from
msg 275, making msg 274 the primary source for sleep staging on this firmware.

Parser behavior: `parseSleepLevel` currently returns `nil` for these records
and falls back to msg 275. Decoding msg 274 directly is a TODO.

This was one of three bugs whose combination caused every sleep session to be
silently dropped pre-fix (commit `75d3efd`).

### 5.6 Msg 275 has no explicit duration on this firmware

Msg 275 (`sleep_stage`) field 1 (`duration`) is **absent** from records on this
device. Compass therefore makes the field optional and derives stage spans
from consecutive timestamps; the final stage extends to the session end from
msg 273. See `SleepFITParser.parseSleepStage` and the buildSleepResult fallback
chain.

### 5.7 Msg 273 field map differs from initial assumption

Before commit `75d3efd`, the parser expected `start = field[2]`,
`end = field[3]`, `score = field[0]`. Live captures show **`start = field[253]`**
(the FIT-standard timestamp convention), **`end = field[2]`**, and
**`score = field[1]`**. Field[3] is always absent. The session-bounds check
always failed pre-fix and every session was dropped.

### 5.8 Msg 318 is undocumented

Every subtype-58 file contains ~66 records of msg 318 (`hsa_event` /
`hsa_unknown`). It is not in the Garmin FIT Python SDK, Gadgetbridge, or the
HarryOnline spreadsheet. Compass currently emits a structured field-dump for
each occurrence; a decode is pending more captures.

### 5.9 Sedentary `activity_type` is 8, not 7

The HarryOnline spreadsheet lists `7 = sedentary`. The USB FIT dump from this
device confirms **`8 = sedentary`** on Instinct Solar 1G fw 19.1. The activity-
type table in §2 reflects the live mapping; `7` does not appear in any
captured records.

### 5.10 Step-count: msg 55 field 3 is raw cumulative steps

When activity_type ∈ {1=running, 6=walking}, **field 3 is the raw cumulative
step count since midnight** — not active_time, and *not* `cycles × 2`. Field 2
(`cycles`) is always 0 on this firmware. Compass computes per-interval deltas
with midnight-rollover handling. For non-step activity types, field 3 reverts
to its FIT-subfield meaning of `active_time` in milliseconds.

### 5.11 Active-minutes allowlist (commit `1394778`)

Msg 55 records frequently arrive with field 5 (`activity_type`) absent, in
which case it defaults to 0 (generic). Generic also covers sleep periods on
this firmware. The original logic excluded only sedentary (8), so overnight
sleep accumulated ~118 spurious intensity minutes per night.

Fix: switch to an **allowlist**. Only running (1), cycling (2),
fitness_equipment (4), swimming (5), and walking (6) contribute one intensity
minute per record. Generic (0) and sedentary (8) both contribute zero.

### 5.12 `LocationUpdatedNotification` does not update sunrise/sunset

Compass sends a `PROTOBUF_RESPONSE (0x13B4)` containing
`Smart → CoreService → LocationUpdatedNotification` (positionType =
`REALTIME_TRACKING`) on connect and on Core Location distance triggers. The
watch ACKs the message with `RESPONSE originalType = 0x13B4 status = ACK`, but
the sunrise/sunset widget on the watch does **not** update.

Likely cause: this protobuf is designed for Garmin's "Connect GPS" feature
(devices borrowing the phone's GPS for indoor workouts). The Instinct Solar 1G
has its own GPS and does not implement this protobuf for home-location or
widget purposes.

How sunset/sunrise actually updates on this device:

- From the watch's own GPS fix during an outdoor activity (automatic, no BLE
  needed).
- From the manually set Home Location (Settings → System → Location → Home
  Location, or via Garmin Connect device settings).

There is no known BLE mechanism to remotely update home location on this
firmware. The phone-location push is harmless and may help other devices, but
should not be relied on for sunrise/sunset on the Instinct Solar 1G. See
[`../gfdi/protobuf.md`](../gfdi/protobuf.md) for protobuf framing.

---

## 6. Related documentation

| Document | Contents |
|----------|----------|
| [`../README.md`](../README.md) | Stack overview and doc index |
| [`../transport/gatt.md`](../transport/gatt.md) | BLE service and characteristic UUIDs |
| [`../transport/multi-link.md`](../transport/multi-link.md) | V2 ML control plane (CLOSE_ALL, REGISTER_ML) |
| [`../transport/cobs.md`](../transport/cobs.md) | COBS framing (with the interleave fix) |
| [`../transport/crc16.md`](../transport/crc16.md) | Garmin nibble-table CRC-16 |
| [`../gfdi/message-format.md`](../gfdi/message-format.md) | Length+type+CRC frame, RESPONSE wrapping |
| [`../gfdi/message-types.md`](../gfdi/message-types.md) | Full message-type catalog |
| [`../gfdi/pairing.md`](../gfdi/pairing.md) | Handshake / authentication / post-init |
| [`../gfdi/file-sync-download.md`](../gfdi/file-sync-download.md) | Watch → phone download (Quirks 5.1, 5.2 originate here) |
| [`../gfdi/file-sync-upload.md`](../gfdi/file-sync-upload.md) | Phone → watch (course upload) |
| [`../gfdi/system-events.md`](../gfdi/system-events.md) | SystemEvent codes (sync lifecycle) |
| [`../gfdi/protobuf.md`](../gfdi/protobuf.md) | PROTOBUF_REQUEST/RESPONSE, LocationUpdatedNotification |
| [`../gfdi/weather.md`](../gfdi/weather.md) | Weather request / FIT_DEFINITION reply |
| [`../fit/format.md`](../fit/format.md) | FIT wire format, headers, base types, CRC |
| [`../fit/compressed-timestamps.md`](../fit/compressed-timestamps.md) | Compressed-timestamp record header |
| [`../fit/messages.md`](../fit/messages.md) | Message catalog (HSA, sleep, monitoring) |
| [`../references/gadgetbridge-pairing.md`](../references/gadgetbridge-pairing.md) | Byte-level GB pairing walkthrough |
| [`../references/gadgetbridge-sync.md`](../references/gadgetbridge-sync.md) | Byte-level GB sync walkthrough |

_Source pointers: `Packages/CompassFIT/Sources/CompassFIT/Parsers/MonitoringFITParser.swift`,
`SleepFITParser.swift`; `Packages/CompassBLE/Sources/CompassBLE/Sync/FileMetadata.swift`;
commits `1394778`, `75d3efd`, `81d8156`, `e756105`, `e8292f9`, `4407e2c`._

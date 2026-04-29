# Garmin Instinct Solar (1st gen) — Device Reference

_Written: 2026-04-29 — based on live BLE captures and USB FIT dump from an Instinct Solar
(1st gen), firmware 19.1, product ID 3466._

> **Device identity note:** The USB dump analysis tool misidentified product 3466 as
> "Instinct 2 Solar Surf". This is incorrect — the device is the original **Garmin Instinct
> Solar (1st gen)**. When searching Gadgetbridge issues, source, or community resources,
> use "Instinct Solar" as the search term, not "Instinct 2" or "Solar Surf".

This document describes the Garmin Instinct Solar (1st gen) as a sync target for Compass:
what health features the device tracks, which FIT files it produces, and how those files
map to Compass data models. It complements the protocol docs (which cover *how* to sync)
with device-level context (what you'll actually get when you do).

---

## Table of Contents

1. [Device Overview](#1-device-overview)
2. [Health Features and Data Sources](#2-health-features-and-data-sources)
3. [FIT Files Produced](#3-fit-files-produced)
4. [Compass Data Model Mapping](#4-compass-data-model-mapping)
5. [Firmware Quirks](#5-firmware-quirks)
6. [Related Documentation](#6-related-documentation)

---

## 1. Device Overview

| Property | Value |
|---|---|
| Model | Garmin Instinct Solar (1st gen) |
| Garmin product ID | 3466 |
| Firmware tested | 19.1 |
| Connectivity | Bluetooth Low Energy (BLE) using Garmin Multi-Link / GFDI protocol |
| Epoch | Garmin epoch: seconds since 1989-12-31 00:00:00 UTC (offset 631,065,600 from Unix) |

The Instinct Solar uses the **legacy GFDI file-sync protocol** (not the newer protobuf
`FileSyncService`). See `../gadgetbridge-sync.md` for the full protocol walkthrough.

---

## 2. Health Features and Data Sources

### Heart Rate

- **Continuous 24/7 HR**: stored in HSA files (subtype 58), message 308 (`hsa_heart_rate_data`)
  as per-second `uint8[]` arrays
- **Per-minute HR during monitoring**: message 140 (`monitoring_hr`) in the subtype-32
  daily monitor file
- **Activity HR**: per-record in activity FIT files (message 20, `record`)
- **Session avg/max HR**: message 18 (`session`), fields 16/17

### Steps and Activity

- **Per-minute intervals**: message 55 (`monitoring`) in the subtype-32 monitor file
  — fields: cycles (→ steps), active_time, active_calories, activity_type
- **Consolidated monitoring**: message 233 (`monitoring_v2`) also appears in the
  subtype-32 file; on Instinct Solar 1G, observed records contain only field[2] = 4B data

Activity type enum (msg 55, field 5 / msg 233, field 1) — as observed on Instinct Solar 1G fw 19.1:

| Value | Meaning |
|---|---|
| 0 | generic |
| 1 | running |
| 2 | cycling |
| 3 | transition |
| 4 | fitness_equipment |
| 5 | swimming |
| 6 | walking |
| 8 | **sedentary** (NOT 7 — confirmed from USB FIT dump) |
| 254 | invalid |

Steps: field 3 of msg 55 carries the **raw cumulative step count since midnight** for
walking (6) or running (1) activity types. **No ×2 scaling** is needed on this firmware
(field 2 / cycles is always 0). Per-interval delta = `field3_current − field3_prev`
(with midnight rollover handled).

### Stress

- **Per-second stress**: HSA files (subtype 58), message 306 (`hsa_stress_data`)
  — field 1: `sint8[]`, 0–100 valid, negative = not measured (see `../fit-messages.md §4`)

### Respiration

- **Per-second breathing rate**: HSA files (subtype 58), message 307 (`hsa_respiration_data`)
  — field 1: `uint8[]` breaths/min, 0=blank, 255=invalid

### Body Battery

- **Per-second body battery**: HSA files (subtype 58), message 314 (`hsa_body_battery_data`)
  — field 1: `sint8[]`, 0–100 valid, -16=blank
- **Point-in-time body battery**: message 346 (`body_battery`) in monitoring files (less common
  on Instinct Solar; may appear in subtype-32 or metrics files)

### Sleep

- **Session metadata**: message 273 (`sleep_data_info`) — score, start, end times
- **Per-minute staging**: message 274 (`sleep_level`) — **primary staging source on this firmware**
  — field 0: 1=awake, 2=light, 3=deep, 4=REM, 0=unmeasurable
- **Quality breakdown**: message 276 (`sleep_assessment`) — ~12 sub-scores (field dump in place,
  full decode pending)
- **Restless moments**: message 382 (`sleep_restless_moments`)

> Message 275 (`sleep_stage`) does **not** appear in Instinct Solar sleep files. Use msg 274 only.

### Training Readiness / HRV

- Message 369 (`training_readiness`) appears in metrics files — field 0: score 0–100
- HRV files (subtype 68, `HRV_STATUS`) have not yet been captured from this device

---

## 3. FIT Files Produced

A typical sync from an Instinct Solar 1G produces files in these categories:

| File subtype | Count (typical) | Content | Compass directory |
|---|---|---|---|
| 128/4 (activity) | 0–N | One per recorded activity | `.activity` |
| 128/32 (monitor) | 1 | Daily monitoring envelope: msg 55 + msg 233 | `.monitor` |
| 128/44 (metrics) | 1 | Aggregate summaries: training readiness, etc. | `.metrics` |
| 128/49 (sleep) | 0–N | One per night: msgs 273–276, 382 | `.sleep` |
| 128/58 (monitorHealth) | 10–12 | HSA sessions: msgs 306–314, 318 | `.monitor` |

### How subtype-58 files relate to subtype-32

The subtype-32 monitor file is a lightweight "today's envelope" — it has a handful of
msg 55 intervals (one per significant activity change) and a handful of msg 233 records.

The **real timeseries data** lives entirely in the subtype-58 files. Each subtype-58 file
represents one contiguous monitoring session (typically a few hours) and contains:

```
msg 162  (timestamp_correlation — anchors the session to UTC)
msg 318  (unknown HSA record — appears ~66× per file)
msg 308  (hsa_heart_rate_data — per-second HR arrays)
msg 306  (hsa_stress_data — per-second stress arrays)
msg 307  (hsa_respiration_data — per-second respiration arrays)
msg 314  (hsa_body_battery_data — per-second body battery arrays)
```

### File flags

After successful download, Compass sends `SetFileFlagsMessage(ARCHIVE = 0x10)` to mark
each file. The watch then excludes archived files from future directory listings. Files
already marked archived are skipped during sync without re-downloading.

---

## 4. Compass Data Model Mapping

| Health feature | FIT source | Compass model |
|---|---|---|
| Heart rate | msg 308 (HSA), msg 140 | `HeartRateSample` |
| Steps / activity | msg 55, msg 233 (pending) | `StepCount` (day aggregate) |
| Active minutes | msg 55 field 5 (activity_type) | `StepCount.intensityMinutes` |
| Stress | msg 306 (HSA) | `StressSample` |
| Respiration | msg 307 (HSA) | `RespirationSample` |
| Body battery | msg 314 (HSA), msg 346 | `BodyBatterySample` |
| Sleep session | msg 273 | `SleepSession` |
| Sleep staging | msg 274 (collapsed into spans) | `SleepStage` |
| Sleep quality | msg 276 (pending) | `SleepSession.recoveryScore`, `.qualifier` |
| Activity workout | msg 18 (session) | `Activity` |

---

## 5. Firmware Quirks

These are divergences from the Gadgetbridge reference behaviour discovered during iOS
implementation. See also `../gadgetbridge-sync.md §14.5` for protocol-layer quirks.

### `DownloadRequestStatus` as full RESPONSE

The Instinct Solar sends `DownloadRequestStatus` (the ACK to a 5002 request) as a full
`RESPONSE (0x1388)` frame rather than the compact-typed `5002 | 0x8000` form. Wait for
`awaitType: .response` when sending a `DownloadRequestMessage`.

The same applies to `SetFileFlagsStatus` (the ACK to 5008 archive requests).

### `downloadStatus=3` with `maxFileSize=0`

Some files return `downloadStatus=3` (NO_SPACE_LEFT) with `maxFileSize=0` in their
`DownloadRequestStatus` while still streaming data immediately. Only gate on `outerStatus==0`;
ignore `downloadStatus`. When `maxFileSize=0`, watch for the last-chunk flag (`flags & 0x08`)
to detect end-of-transfer.

### Subtype 58 files not recognised before fix

Before `monitorHealth` was added to `FileType.swift`, all subtype-58 files were silently
skipped — producing zero HR, stress, body battery, and respiration even though the watch
reported hours of data. The fix was adding `case monitorHealth = 58` to `FileType` and
mapping it to the `.monitor` directory in `FITDirectory`.

### Message 233 carries minimal data

The subtype-32 monitor file's msg 233 records contain only `field[2] = data(4 bytes)` on
this firmware. All the useful health data is in the subtype-58 HSA files, not in msg 233.

### Message 318 is undocumented

Every subtype-58 file contains ~66 records of message 318. This message is not in the
Garmin FIT Python SDK, Gadgetbridge, or the HarryOnline spreadsheet. Field dump is in
place; field structure will be known after the next sync.

---

## 6. Related Documentation

| Document | Contents |
|---|---|
| `gadgetbridge-pairing.md` | BLE pairing: Multi-Link, COBS, GFDI, auth sequence |
| `../gadgetbridge-sync.md` | GFDI sync protocol: file listing, download, upload, archive |
| `../fit-messages.md` | FIT message type reference: HSA family, sleep messages, overlay coverage |
| `../../plans/fit-parsing-plan.md` | Implementation plan for FIT parsers (steps, status) |

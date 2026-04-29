# Weather Service — Garmin Instinct

How Compass responds to watch-initiated weather requests over GFDI/BLE.

---

## Overview

The watch periodically asks the phone for weather data. The phone responds with
inline FIT messages on the GFDI link (no file transfer involved). When the
response is complete and correct the watch stops asking; if the response is
missing or malformed it retries every ~5 seconds.

---

## Message sequence

```
Watch                               Phone
  │                                   │
  │── WEATHER_REQUEST (0x1396) ──────▶│  payload: format(1) lat(4) lon(4) hours(1)
  │                                   │
  │◀─ RESPONSE ACK   (0x1388) ────────│  ACK the request before doing async work
  │                                   │
  │◀─ FIT_DEFINITION (0x1393) ────────│  declares three local message types
  │                                   │
  │── RESPONSE ACK   (0x1388) ──────▶│  watch acknowledges the definition
  │                                   │
  │◀─ FIT_DATA       (0x1394) ────────│  all weather records in one message
  │                                   │
  │── RESPONSE ACK   (0x1388) ──────▶│  watch acknowledges the data
  │                                   │
  ╌  (watch stops requesting)          │
```

The ACK for WEATHER_REQUEST is sent first so the watch does not time out while
the app is awaiting async weather data.

---

## WEATHER_REQUEST payload (watch → phone)

| Offset | Size | Type   | Field            | Notes                                    |
|--------|------|--------|------------------|------------------------------------------|
| 0      | 1    | uint8  | format           | parsed but not acted on (GB ignores it)  |
| 1      | 4    | sint32 | latitude         | semicircles; `0x7FFFFFFF` = no GPS fix   |
| 5      | 4    | sint32 | longitude        | semicircles; `0x7FFFFFFF` = no GPS fix   |
| 9      | 1    | uint8  | hoursOfForecast  | typically 12                             |

Coordinates in semicircles: `degrees = value × (180 / 2³¹)`.  
If either coordinate is `Int32.max` (FIT invalid sentinel) the phone substitutes
`0, 0` so the watch does not discard the record.

---

## FIT_DEFINITION (0x1393)

One GFDI message whose payload is **three consecutive FIT definition blocks**,
one per local message type. All blocks use global FIT message number **128**
(`weather_conditions`), little-endian architecture.

### Local message 6 — TODAY\_WEATHER\_CONDITIONS

FIT record header byte: `0x46` (`0x40 | 6`)

| # | Field def | Name                   | Size | Base type |
|---|-----------|------------------------|------|-----------|
| 1 | 0         | weather\_report        | 1    | ENUM      |
| 2 | 253       | timestamp              | 4    | UINT32    |
| 3 | 9         | observed\_at\_time     | 4    | UINT32    |
| 4 | 1         | temperature            | 1    | SINT8     |
| 5 | 14        | low\_temperature       | 1    | SINT8     |
| 6 | 13        | high\_temperature      | 1    | SINT8     |
| 7 | 2         | condition              | 1    | ENUM      |
| 8 | 3         | wind\_direction        | 2    | UINT16    |
| 9 | 5         | precipitation\_prob    | 1    | UINT8     |
|10 | 4         | wind\_speed            | 2    | UINT16    |
|11 | 6         | temperature\_feels\_like | 1  | SINT8     |
|12 | 7         | relative\_humidity     | 1    | UINT8     |
|13 | 10        | observed\_location\_lat | 4   | SINT32    |
|14 | 11        | observed\_location\_long | 4  | SINT32    |
|15 | 17        | air\_quality           | 1    | ENUM      |
|16 | 15        | dew\_point             | 1    | SINT8     |
|17 | 8         | location               | 15   | STRING    |

### Local message 9 — HOURLY\_WEATHER\_FORECAST

FIT record header byte: `0x49` (`0x40 | 9`)

| # | Field def | Name                     | Size | Base type |
|---|-----------|--------------------------|------|-----------|
| 1 | 0         | weather\_report          | 1    | ENUM      |
| 2 | 253       | timestamp                | 4    | UINT32    |
| 3 | 1         | temperature              | 1    | SINT8     |
| 4 | 2         | condition                | 1    | ENUM      |
| 5 | 3         | wind\_direction          | 2    | UINT16    |
| 6 | 4         | wind\_speed              | 2    | UINT16    |
| 7 | 5         | precipitation\_prob      | 1    | UINT8     |
| 8 | 6         | temperature\_feels\_like | 1    | SINT8     |
| 9 | 7         | relative\_humidity       | 1    | UINT8     |
|10 | 15        | dew\_point               | 1    | SINT8     |
|11 | 16        | uv\_index                | 4    | FLOAT32   |
|12 | 17        | air\_quality             | 1    | ENUM      |

### Local message 10 — DAILY\_WEATHER\_FORECAST

FIT record header byte: `0x4A` (`0x40 | 10`)

| # | Field def | Name                  | Size | Base type |
|---|-----------|-----------------------|------|-----------|
| 1 | 0         | weather\_report       | 1    | ENUM      |
| 2 | 253       | timestamp             | 4    | UINT32    |
| 3 | 14        | low\_temperature      | 1    | SINT8     |
| 4 | 13        | high\_temperature     | 1    | SINT8     |
| 5 | 2         | condition             | 1    | ENUM      |
| 6 | 5         | precipitation\_prob   | 1    | UINT8     |
| 7 | 12        | day\_of\_week         | 1    | ENUM      |
| 8 | 17        | air\_quality          | 1    | ENUM      |

---

## FIT_DATA (0x1394)

One GFDI message whose payload is **all records concatenated** in this order:

1. **1× local msg 6** record — current conditions (`weather_report = 0`)
2. **12× local msg 9** records — hourly forecasts (`weather_report = 1`), one per hour starting at now+1h
3. **5× local msg 10** records — daily forecasts (`weather_report = 2`), today through today+4 days

Each record starts with its FIT data record header byte (`0x06`, `0x09`, or `0x0A`),
followed by field values in the order declared in the definition above.

### FIT invalid values (used for fields we don't populate)

| Base type | Invalid sentinel |
|-----------|-----------------|
| ENUM      | `0xFF`          |
| SINT8     | `0x7F`          |
| FLOAT32   | `0xFFFFFFFF`    |

Fields `air_quality` (17), `dew_point` (15), and `uv_index` (16) are always
sent as their respective invalid sentinels in the stub implementation.

---

## Condition codes (`weather_report` field 2)

| Code | Garmin label        |
|------|---------------------|
| 0    | Clear / sunny       |
| 1    | Partly cloudy       |
| 3    | Mostly cloudy       |
| 5    | Rain                |
| 6    | Snow                |
| 7    | Windy               |
| 8    | Fog / haze          |
| 13   | Cloudy              |
| 15   | Thunderstorms       |

---

## Timestamps

All timestamps are **Garmin epoch** (seconds since 1989-12-31 00:00:00 UTC).

```
garmin_ts = unix_ts - 631_065_600
```

---

## What this does NOT affect

- **Sunset / sunrise widget** — computed by the watch from its stored "home
  location" (set in watch settings or pushed by Garmin Connect). The
  `observed_location_lat/long` fields in the weather response are for labelling
  the weather source only; they do not update the watch's stored location.
  A separate `PhoneLocation` protobuf push would be needed for that.

- **GPS ephemeris** — unrelated; handled by a different GFDI file-transfer flow.

---

## Stub vs real WeatherKit

`WeatherService.swift` currently returns fixed stub data (18 °C partly cloudy,
plus a rotating forecast pattern) so the app compiles without the
`com.apple.developer.weatherkit` entitlement. The full WeatherKit implementation
is preserved as a comment block in that file. To activate it:

1. Add `com.apple.developer.weatherkit: true` to `Compass.entitlements`.
2. Enable WeatherKit on the App ID in developer.apple.com.
3. Swap the comment block into the `buildFITMessages` method body.

---

## Source files

| File | Role |
|------|------|
| `Packages/CompassBLE/Sources/CompassBLE/GFDI/Messages/WeatherFIT.swift` | FIT encoder + request parser + public data types |
| `Packages/CompassBLE/Sources/CompassBLE/Public/DeviceServiceCallbacks.swift` | `WeatherRequest` struct |
| `Compass/Services/WeatherService.swift` | App-layer: builds `GarminCurrentConditions`, `GarminHourlyForecast`, `GarminDailyForecast` and calls the encoder |
| `Compass/App/SyncCoordinator.swift` | Wires `WeatherService` into `GarminDeviceManager.weatherProvider` after connect |

---

## Reference

Field definitions verified against Gadgetbridge
[`PredefinedLocalMessage.java`](https://github.com/Freeyourgadget/Gadgetbridge/blob/master/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/garmin/fit/PredefinedLocalMessage.java)
and
[`GlobalFITMessage.java`](https://github.com/Freeyourgadget/Gadgetbridge/blob/master/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/garmin/fit/GlobalFITMessage.java).
`sendWeatherConditions` in `GarminSupport.java` is the authoritative sequence reference.

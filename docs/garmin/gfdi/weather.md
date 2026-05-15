# Weather (WEATHER_REQUEST)

How Compass answers the watch's `WEATHER_REQUEST` (5014 / 0x1396) by emitting
inline FIT messages that contain current conditions, hourly forecasts, and a
multi-day forecast.

The watch retransmits `WEATHER_REQUEST` roughly every five seconds until it
receives a `RESPONSE` ACK — without that ACK the FIT payload is interpreted as
unrelated unsolicited traffic, so ordering matters.

See also: [`./message-format.md`](./message-format.md),
[`./message-types.md`](./message-types.md), [`../fit/messages.md`](../fit/messages.md).

## Sequence

| Step | Direction   | GFDI type                  | Notes                              |
|------|-------------|----------------------------|------------------------------------|
| 1    | watch → app | `WEATHER_REQUEST` (5014)   | 10-byte payload (see below)        |
| 2    | app → watch | `RESPONSE` (5000) ACK      | bare ACK, no extra bytes           |
| 3    | app → watch | `FIT_DEFINITION` (5011)    | local msg defs 6, 9, 10            |
| 4    | app → watch | `FIT_DATA` (5012)          | one current + N hourly + M daily   |

This ACK-first ordering was fixed in commit `4407e2c`. If the FIT pair is sent
without the ACK first, the watch keeps retransmitting `WEATHER_REQUEST` and the
phone gets stuck in a fetch storm.

Compass: `GarminDeviceManager.swift:354-389` (`handleWeatherRequest`).

## WEATHER_REQUEST payload

10 bytes, all little-endian:

| Offset | Size | Field                | Notes                                          |
|--------|------|----------------------|------------------------------------------------|
| 0      | 1    | `format`             | request format flag (typically 0)              |
| 1      | 4    | `latitude`           | `Int32` semicircles                            |
| 5      | 4    | `longitude`          | `Int32` semicircles                            |
| 9      | 1    | `hoursOfForecast`    | requested hourly horizon                       |

Decoded by `WeatherRequestParser.decode` at `WeatherFIT.swift:106-120`.

### Semicircles

Garmin lat/lon are stored as `sint32` semicircles. Conversion:

```
degrees = value × (180 / 2³¹)
```

A watch with no GPS fix sends `0x7FFFFFFF` (`Int32.max`, the FIT invalid
sentinel). Compass clamps that to `(0, 0)` so the FIT response still validates
on the watch:

```swift
private func clampedCoords(from request: WeatherRequest) -> (Int32, Int32) {
    (
        request.latitudeSemicircles  == Int32.max ? 0 : request.latitudeSemicircles,
        request.longitudeSemicircles == Int32.max ? 0 : request.longitudeSemicircles
    )
}
```

Compass: `WeatherService.swift:103-108`.

## Re-entrancy guard

WeatherKit calls take 1–3 s and the watch retransmits every ~5 s, so naïvely
launching one fetch per request causes overlapping work and double sends.
`GarminDeviceManager` holds a single boolean:

```swift
private var weatherRequestInFlight = false
…
guard !weatherRequestInFlight else {
    BLELogger.gfdi.debug("WEATHER_REQUEST: fetch already in flight, skipping duplicate")
    return
}
…
weatherRequestInFlight = true
defer { weatherRequestInFlight = false }
```

Compass: `GarminDeviceManager.swift:52, 355-379`.

## FIT framing

Compass emits one `FIT_DEFINITION` followed by one `FIT_DATA`. Both reuse the
global FIT message number `128` (`weather_conditions`), distinguishing the
record kind via three local message numbers chosen to match Gadgetbridge's
`PredefinedLocalMessage`:

| Local msg | Constant                  | Records emitted | `weather_report` |
|-----------|---------------------------|-----------------|------------------|
| 6         | `TODAY_WEATHER_CONDITIONS`| exactly 1       | 0                |
| 9         | `HOURLY_WEATHER_FORECAST` | up to 12        | 1                |
| 10        | `DAILY_WEATHER_FORECAST`  | up to 5         | 2                |

`FIT_DEFINITION` records use the standard FIT definition header `0x40 | localMsg`,
reserved byte `0x00`, architecture byte `0x00` (little-endian), the global
message number `0x0080` LE, and a (field_def_num, size, base_type) triple per
field.

Compass: `WeatherFIT.swift:246-269` (`appendDefinitionBlock`).

### Local msg 6 — current conditions

Field order matches `WeatherFIT.swift:185-203`.

| field_def_num | name                       | base type | size |
|---------------|----------------------------|-----------|------|
| 0             | weather_report             | enum      | 1    |
| 253           | timestamp                  | uint32    | 4    |
| 9             | observed_at_time           | uint32    | 4    |
| 1             | temperature                | sint8     | 1    |
| 14            | low_temperature            | sint8     | 1    |
| 13            | high_temperature           | sint8     | 1    |
| 2             | condition                  | enum      | 1    |
| 3             | wind_direction             | uint16    | 2    |
| 5             | precipitation_probability  | uint8     | 1    |
| 4             | wind_speed (km/h)          | uint16    | 2    |
| 6             | temperature_feels_like     | sint8     | 1    |
| 7             | relative_humidity          | uint8     | 1    |
| 10            | observed_location_lat      | sint32    | 4    |
| 11            | observed_location_long     | sint32    | 4    |
| 17            | air_quality                | enum      | 1    |
| 15            | dew_point                  | sint8     | 1    |
| 8             | location                   | string    | 15   |

Compass writes the FIT invalid sentinel `0xFF` for `air_quality` and `0x7F` for
`dew_point` (`WeatherFIT.swift:301-302`).

### Local msg 9 — hourly forecast

Field order matches `WeatherFIT.swift:206-219`.

| field_def_num | name                       | base type | size |
|---------------|----------------------------|-----------|------|
| 0             | weather_report             | enum      | 1    |
| 253           | timestamp                  | uint32    | 4    |
| 1             | temperature                | sint8     | 1    |
| 2             | condition                  | enum      | 1    |
| 3             | wind_direction             | uint16    | 2    |
| 4             | wind_speed (km/h)          | uint16    | 2    |
| 5             | precipitation_probability  | uint8     | 1    |
| 6             | temperature_feels_like     | sint8     | 1    |
| 7             | relative_humidity          | uint8     | 1    |
| 15            | dew_point                  | sint8     | 1    |
| 16            | uv_index                   | float32   | 4    |
| 17            | air_quality                | enum      | 1    |

`uv_index` is filled with FLOAT32 invalid (`0xFFFFFFFF`) and the two enum
fields with `0xFF` (`WeatherFIT.swift:319-322`).

### Local msg 10 — daily forecast

Field order matches `WeatherFIT.swift:222-231`.

| field_def_num | name                       | base type | size |
|---------------|----------------------------|-----------|------|
| 0             | weather_report             | enum      | 1    |
| 253           | timestamp                  | uint32    | 4    |
| 14            | low_temperature            | sint8     | 1    |
| 13            | high_temperature           | sint8     | 1    |
| 2             | condition                  | enum      | 1    |
| 5             | precipitation_probability  | uint8     | 1    |
| 12            | day_of_week                | enum      | 1    |
| 17            | air_quality                | enum      | 1    |

`day_of_week` follows Garmin's convention: `0=Sun…6=Sat`. Compass derives it
via `(Calendar.weekday − 1 + 7) % 7` so the Apple Sunday-first ordinal matches
(`WeatherService.swift:88`).

## Time base

All `timestamp` and `observed_at_time` fields are seconds since the Garmin FIT
epoch (`1989-12-31 00:00:00 UTC`, offset `631_065_600` from the Unix epoch).
Compass converts via `WeatherService.garminTimestamp(from:)`
(`WeatherService.swift:110-113`).

## Why a stub?

`WeatherKit` requires the `com.apple.developer.weatherkit` entitlement, which
needs Apple-side approval. Until that is provisioned, `WeatherService` returns
plausible example data so the watch is satisfied and stops retransmitting.
The full WeatherKit implementation is preserved as a comment block at
`WeatherService.swift:116-194`.

## References

- Compass: `Packages/CompassBLE/Sources/CompassBLE/GFDI/Messages/WeatherFIT.swift`
- Compass: `Compass/Services/WeatherService.swift`
- Compass: `Packages/CompassBLE/Sources/CompassBLE/Public/GarminDeviceManager.swift:354-389`
- Gadgetbridge: `WeatherMessage.java`, `PredefinedLocalMessage.java`
- Garmin FIT SDK: `weather_conditions` (mesg_num 128) — see [`../fit/messages.md`](../fit/messages.md)
- Commit `4407e2c` — fix ACK-first ordering for `WEATHER_REQUEST`

Source: [`WeatherFIT.swift`](../../../Packages/CompassBLE/Sources/CompassBLE/GFDI/Messages/WeatherFIT.swift),
[`WeatherService.swift`](../../../Compass/Services/WeatherService.swift),
[`GarminDeviceManager.swift`](../../../Packages/CompassBLE/Sources/CompassBLE/Public/GarminDeviceManager.swift).

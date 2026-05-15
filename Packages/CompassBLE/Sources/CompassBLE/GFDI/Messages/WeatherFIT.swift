import Foundation

// MARK: - Public data types

/// Current conditions record — local FIT message type 6 (TODAY_WEATHER_CONDITIONS).
public struct GarminCurrentConditions: Sendable {
    public let timestamp: UInt32
    public let observedAtTime: UInt32
    public let temperature: Int8
    public let lowTemperature: Int8
    public let highTemperature: Int8
    public let condition: UInt8
    public let windDirection: UInt16
    public let precipitationProbability: UInt8
    public let windSpeed: UInt16
    public let temperatureFeelsLike: Int8
    public let relativeHumidity: UInt8
    public let observedLocationLat: Int32
    public let observedLocationLong: Int32
    public let location: String

    public init(
        timestamp: UInt32, observedAtTime: UInt32,
        temperature: Int8, lowTemperature: Int8, highTemperature: Int8,
        condition: UInt8, windDirection: UInt16, precipitationProbability: UInt8,
        windSpeed: UInt16, temperatureFeelsLike: Int8, relativeHumidity: UInt8,
        observedLocationLat: Int32, observedLocationLong: Int32, location: String
    ) {
        self.timestamp = timestamp
        self.observedAtTime = observedAtTime
        self.temperature = temperature
        self.lowTemperature = lowTemperature
        self.highTemperature = highTemperature
        self.condition = condition
        self.windDirection = windDirection
        self.precipitationProbability = precipitationProbability
        self.windSpeed = windSpeed
        self.temperatureFeelsLike = temperatureFeelsLike
        self.relativeHumidity = relativeHumidity
        self.observedLocationLat = observedLocationLat
        self.observedLocationLong = observedLocationLong
        self.location = location
    }
}

/// One hourly forecast record — local FIT message type 9 (HOURLY_WEATHER_FORECAST).
public struct GarminHourlyForecast: Sendable {
    public let timestamp: UInt32
    public let temperature: Int8
    public let condition: UInt8
    public let windDirection: UInt16
    public let windSpeed: UInt16
    public let precipitationProbability: UInt8
    public let temperatureFeelsLike: Int8
    public let relativeHumidity: UInt8

    public init(
        timestamp: UInt32, temperature: Int8, condition: UInt8,
        windDirection: UInt16, windSpeed: UInt16,
        precipitationProbability: UInt8, temperatureFeelsLike: Int8, relativeHumidity: UInt8
    ) {
        self.timestamp = timestamp
        self.temperature = temperature
        self.condition = condition
        self.windDirection = windDirection
        self.windSpeed = windSpeed
        self.precipitationProbability = precipitationProbability
        self.temperatureFeelsLike = temperatureFeelsLike
        self.relativeHumidity = relativeHumidity
    }
}

/// One daily forecast record — local FIT message type 10 (DAILY_WEATHER_FORECAST).
public struct GarminDailyForecast: Sendable {
    public let timestamp: UInt32
    public let lowTemperature: Int8
    public let highTemperature: Int8
    public let condition: UInt8
    public let precipitationProbability: UInt8
    public let dayOfWeek: UInt8

    public init(
        timestamp: UInt32, lowTemperature: Int8, highTemperature: Int8,
        condition: UInt8, precipitationProbability: UInt8, dayOfWeek: UInt8
    ) {
        self.timestamp = timestamp
        self.lowTemperature = lowTemperature
        self.highTemperature = highTemperature
        self.condition = condition
        self.precipitationProbability = precipitationProbability
        self.dayOfWeek = dayOfWeek
    }
}

// MARK: - WEATHER_REQUEST parser

/// Parses WEATHER_REQUEST (5014 / 0x1396) payloads from the watch.
///
/// Wire format:
/// ```
/// [format:          UInt8]
/// [latitude:        Int32 LE]   semicircles
/// [longitude:       Int32 LE]   semicircles
/// [hoursOfForecast: UInt8]
/// ```
public enum WeatherRequestParser {
    public static func decode(from payload: Data) throws -> WeatherRequest {
        var reader = ByteReader(data: payload)
        let format = try reader.readUInt8()
        let lat    = try reader.readInt32LE()
        let lon    = try reader.readInt32LE()
        let hours  = try reader.readUInt8()
        return WeatherRequest(
            format: format,
            latitudeSemicircles: lat,
            longitudeSemicircles: lon,
            hoursOfForecast: hours
        )
    }
}

// MARK: - WeatherFITEncoder

/// Encodes weather data as inline FIT messages matching Gadgetbridge's
/// `sendWeatherConditions` protocol exactly.
///
/// Structure (matches Gadgetbridge `PredefinedLocalMessage`):
///
/// **FIT_DEFINITION** (5011): one message containing three record type definitions:
///   - Local msg 6  (`TODAY_WEATHER_CONDITIONS`) — current conditions
///   - Local msg 9  (`HOURLY_WEATHER_FORECAST`)  — per-hour forecasts
///   - Local msg 10 (`DAILY_WEATHER_FORECAST`)   — per-day forecasts
///
/// **FIT_DATA** (5012): one message containing all records concatenated:
///   - 1× local msg 6 record  (`weather_report` = 0)
///   - Up to 12× local msg 9 records  (`weather_report` = 1)
///   - Up to 5× local msg 10 records  (`weather_report` = 2)
///
/// Field reference (GlobalFITMessage.WEATHER, mesg_num=128):
/// ```
///  0  weather_report         ENUM    1 B
///  1  temperature            SINT8   1 B
///  2  condition              ENUM    1 B
///  3  wind_direction         UINT16  2 B
///  4  wind_speed             UINT16  2 B   mm/s
///  5  precipitation_prob     UINT8   1 B
///  6  temperature_feels_like SINT8   1 B
///  7  relative_humidity      UINT8   1 B
///  8  location               STRING 15 B
///  9  observed_at_time       UINT32  4 B   Garmin epoch
/// 10  observed_location_lat  SINT32  4 B   semicircles
/// 11  observed_location_long SINT32  4 B   semicircles
/// 12  day_of_week            ENUM    1 B   0=Sun…6=Sat
/// 13  high_temperature       SINT8   1 B
/// 14  low_temperature        SINT8   1 B
/// 15  dew_point              SINT8   1 B
/// 16  uv_index               FLOAT32 4 B
/// 17  air_quality            ENUM    1 B
/// 253 timestamp              UINT32  4 B   Garmin epoch
/// ```
public enum WeatherFITEncoder {

    // FIT base-type bytes
    private static let enum_:   UInt8 = 0x00
    private static let sint8:   UInt8 = 0x01
    private static let uint8:   UInt8 = 0x02
    private static let uint16:  UInt8 = 0x84
    private static let sint32:  UInt8 = 0x85
    private static let uint32:  UInt8 = 0x86
    private static let string:  UInt8 = 0x07
    private static let float32: UInt8 = 0x88

    private static let globalMsgNum:   UInt16 = 128
    private static let locationSize:   UInt8  = 15

    // Local message numbers — must match Gadgetbridge PredefinedLocalMessage.
    private static let localToday:  UInt8 = 6
    private static let localHourly: UInt8 = 9
    private static let localDaily:  UInt8 = 10

    // Field sets per local message (field_def_num, size_bytes, base_type_byte).
    // Order matches Gadgetbridge PredefinedLocalMessage field arrays exactly.

    // TODAY: [0, 253, 9, 1, 14, 13, 2, 3, 5, 4, 6, 7, 10, 11, 17, 15, 8]
    private static let fieldsToday: [(UInt8, UInt8, UInt8)] = [
        (  0,  1,  enum_),            // weather_report
        (253,  4,  uint32),           // timestamp
        (  9,  4,  uint32),           // observed_at_time
        (  1,  1,  sint8),            // temperature
        ( 14,  1,  sint8),            // low_temperature
        ( 13,  1,  sint8),            // high_temperature
        (  2,  1,  enum_),            // condition
        (  3,  2,  uint16),           // wind_direction
        (  5,  1,  uint8),            // precipitation_probability
        (  4,  2,  uint16),           // wind_speed
        (  6,  1,  sint8),            // temperature_feels_like
        (  7,  1,  uint8),            // relative_humidity
        ( 10,  4,  sint32),           // observed_location_lat
        ( 11,  4,  sint32),           // observed_location_long
        ( 17,  1,  enum_),            // air_quality   (0xFF = invalid)
        ( 15,  1,  sint8),            // dew_point     (0x7F = invalid)
        (  8,  locationSize, string), // location
    ]

    // HOURLY: [0, 253, 1, 2, 3, 4, 5, 6, 7, 15, 16, 17]
    private static let fieldsHourly: [(UInt8, UInt8, UInt8)] = [
        (  0,  1,  enum_),   // weather_report
        (253,  4,  uint32),  // timestamp
        (  1,  1,  sint8),   // temperature
        (  2,  1,  enum_),   // condition
        (  3,  2,  uint16),  // wind_direction
        (  4,  2,  uint16),  // wind_speed
        (  5,  1,  uint8),   // precipitation_probability
        (  6,  1,  sint8),   // temperature_feels_like
        (  7,  1,  uint8),   // relative_humidity
        ( 15,  1,  sint8),   // dew_point  (0x7F = invalid)
        ( 16,  4,  float32), // uv_index   (0xFFFFFFFF = invalid)
        ( 17,  1,  enum_),   // air_quality (0xFF = invalid)
    ]

    // DAILY: [0, 253, 14, 13, 2, 5, 12, 17]
    private static let fieldsDaily: [(UInt8, UInt8, UInt8)] = [
        (  0,  1,  enum_),   // weather_report
        (253,  4,  uint32),  // timestamp
        ( 14,  1,  sint8),   // low_temperature
        ( 13,  1,  sint8),   // high_temperature
        (  2,  1,  enum_),   // condition
        (  5,  1,  uint8),   // precipitation_probability
        ( 12,  1,  enum_),   // day_of_week
        ( 17,  1,  enum_),   // air_quality (0xFF = invalid)
    ]

    // MARK: - Public API

    /// One-shot fingerprint log so we can prove which encoder is compiled
    /// in. If this prints field counts that don't match the source arrays
    /// (today=17, hourly=12, daily=8), the binary was built from different
    /// source than what's in this file — local edits, stale derived data,
    /// wrong worktree, etc. Lazy static init is thread-safe in Swift, so
    /// this fires exactly once per process the first time it's referenced.
    private static let fingerprintToken: Void = {
        BLELogger.gfdi.info(
            "WeatherFITEncoder fingerprint: today=\(fieldsToday.count) "
          + "hourly=\(fieldsHourly.count) daily=\(fieldsDaily.count) "
          + "(expected today=17 hourly=12 daily=8)"
        )
        let hourlyNums = fieldsHourly.map { String($0.0) }.joined(separator: ",")
        let dailyNums  = fieldsDaily.map  { String($0.0) }.joined(separator: ",")
        BLELogger.gfdi.info("WeatherFITEncoder hourly field nums=[\(hourlyNums)]")
        BLELogger.gfdi.info("WeatherFITEncoder daily  field nums=[\(dailyNums)]")
    }()

    /// Returns `[FIT_DEFINITION, FIT_DATA]` ready to send over GFDI.
    public static func encode(
        current: GarminCurrentConditions,
        hourly: [GarminHourlyForecast],
        daily: [GarminDailyForecast]
    ) -> [GFDIMessage] {
        _ = fingerprintToken
        let messages = [
            buildDefinitionMessage(),
            buildDataMessage(current: current, hourly: hourly, daily: daily),
        ]
        let defLen = messages[0].payload.count
        let dataLen = messages[1].payload.count
        BLELogger.gfdi.info(
            "WeatherFITEncoder.encode: def_payload=\(defLen)B data_payload=\(dataLen)B "
          + "(records: 1 today + \(hourly.count) hourly + \(daily.count) daily)"
        )
        return messages
    }

    // MARK: - FIT_DEFINITION

    private static func buildDefinitionMessage() -> GFDIMessage {
        var payload = Data()
        appendDefinitionBlock(into: &payload, localMsg: localToday,  fields: fieldsToday)
        appendDefinitionBlock(into: &payload, localMsg: localHourly, fields: fieldsHourly)
        appendDefinitionBlock(into: &payload, localMsg: localDaily,  fields: fieldsDaily)
        return GFDIMessage(type: .fitDefinition, payload: payload)
    }

    private static func appendDefinitionBlock(
        into payload: inout Data,
        localMsg: UInt8,
        fields: [(UInt8, UInt8, UInt8)]
    ) {
        payload.append(0x40 | localMsg)        // FIT definition record header
        payload.append(0x00)                   // reserved
        payload.append(0x00)                   // architecture = little-endian
        payload.appendUInt16LE(globalMsgNum)   // global message number (128)
        payload.append(UInt8(fields.count))    // field count
        for (defNum, size, baseType) in fields {
            payload.append(defNum)
            payload.append(size)
            payload.append(baseType)
        }
    }

    // MARK: - FIT_DATA

    private static func buildDataMessage(
        current: GarminCurrentConditions,
        hourly: [GarminHourlyForecast],
        daily: [GarminDailyForecast]
    ) -> GFDIMessage {
        var payload = Data()
        appendTodayRecord(into: &payload, c: current)
        for h in hourly { appendHourlyRecord(into: &payload, h: h) }
        for d in daily  { appendDailyRecord(into: &payload,  d: d) }
        return GFDIMessage(type: .fitData, payload: payload)
    }

    private static func appendTodayRecord(into payload: inout Data, c: GarminCurrentConditions) {
        payload.append(localToday)                      // FIT data record header (local msg 6)
        payload.append(0)                               // weather_report = 0 (current conditions)
        payload.appendUInt32LE(c.timestamp)
        payload.appendUInt32LE(c.observedAtTime)
        payload.appendInt8(c.temperature)
        payload.appendInt8(c.lowTemperature)
        payload.appendInt8(c.highTemperature)
        payload.append(c.condition)
        payload.appendUInt16LE(c.windDirection)
        payload.append(c.precipitationProbability)
        payload.appendUInt16LE(c.windSpeed)
        payload.appendInt8(c.temperatureFeelsLike)
        payload.append(c.relativeHumidity)
        payload.appendInt32LE(c.observedLocationLat)
        payload.appendInt32LE(c.observedLocationLong)
        payload.append(0xFF)                            // air_quality:  FIT invalid (ENUM)
        payload.append(0x7F)                            // dew_point:    FIT invalid (SINT8)
        var locBytes = Array(c.location.utf8.prefix(Int(locationSize) - 1))
        while locBytes.count < Int(locationSize) { locBytes.append(0) }
        payload.append(contentsOf: locBytes)
    }

    private static func appendHourlyRecord(into payload: inout Data, h: GarminHourlyForecast) {
        payload.append(localHourly)                     // FIT data record header (local msg 9)
        payload.append(1)                               // weather_report = 1 (hourly forecast)
        payload.appendUInt32LE(h.timestamp)
        payload.appendInt8(h.temperature)
        payload.append(h.condition)
        payload.appendUInt16LE(h.windDirection)
        payload.appendUInt16LE(h.windSpeed)
        payload.append(h.precipitationProbability)
        payload.appendInt8(h.temperatureFeelsLike)
        payload.append(h.relativeHumidity)
        payload.append(0x7F)                            // dew_point:  FIT invalid (SINT8)
        payload.append(0xFF); payload.append(0xFF)      // uv_index:   FIT invalid (FLOAT32 hi)
        payload.append(0xFF); payload.append(0xFF)      // uv_index:   FIT invalid (FLOAT32 lo)
        payload.append(0xFF)                            // air_quality: FIT invalid (ENUM)
    }

    private static func appendDailyRecord(into payload: inout Data, d: GarminDailyForecast) {
        payload.append(localDaily)                      // FIT data record header (local msg 10)
        payload.append(2)                               // weather_report = 2 (daily forecast)
        payload.appendUInt32LE(d.timestamp)
        payload.appendInt8(d.lowTemperature)
        payload.appendInt8(d.highTemperature)
        payload.append(d.condition)
        payload.append(d.precipitationProbability)
        payload.append(d.dayOfWeek)
        payload.append(0xFF)                            // air_quality: FIT invalid (ENUM)
    }
}

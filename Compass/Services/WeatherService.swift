import Foundation
import CoreLocation
import WeatherKit
import CompassBLE

/// Encodes weather data as inline FIT messages for the watch in response to
/// WEATHER_REQUEST. Uses the phone's location (not the watch's), since the
/// watch typically has no GPS fix outside of an active recording.
@MainActor
final class WeatherService {

    enum WeatherServiceError: Error {
        case noPhoneLocation
    }

    /// Returns the phone's most recent location, or nil if none is available
    /// yet. Wired by SyncCoordinator to PhoneLocationService.
    var locationProvider: @MainActor () -> CLLocation? = { nil }

    private static let garminEpochOffset: TimeInterval = 631_065_600

    func buildFITMessages(for request: WeatherRequest) async throws -> [GFDIMessage] {
        guard let phoneLocation = locationProvider() else {
            AppLogger.services.info("Weather: skipping — no phone location yet")
            throw WeatherServiceError.noPhoneLocation
        }

        let weather = try await WeatherKit.WeatherService.shared.weather(for: phoneLocation)
        let now = Date()
        let nowGarmin = garminTimestamp(from: now)
        let today = weather.dailyForecast.first
        let (lat, lon) = semicircles(from: phoneLocation.coordinate)

        let current = GarminCurrentConditions(
            timestamp: nowGarmin,
            observedAtTime: garminTimestamp(from: weather.currentWeather.date),
            temperature: celsiusInt8(weather.currentWeather.temperature),
            lowTemperature: today.map { celsiusInt8($0.lowTemperature) } ?? 0,
            highTemperature: today.map { celsiusInt8($0.highTemperature) } ?? 0,
            condition: mapCondition(weather.currentWeather.condition),
            windDirection: degreesUInt16(weather.currentWeather.wind.direction),
            precipitationProbability: percentUInt8(today?.precipitationChance ?? 0),
            windSpeed: windSpeedMillimetersPerSecond(weather.currentWeather.wind.speed),
            temperatureFeelsLike: celsiusInt8(weather.currentWeather.apparentTemperature),
            relativeHumidity: percentUInt8(weather.currentWeather.humidity),
            observedLocationLat: lat,
            observedLocationLong: lon,
            location: ""
        )

        // WeatherKit's hourly forecast starts at the top of the *current* hour
        // (e.g. 12:00 even when now is 12:34). Keep the entry whose hour-long
        // window contains "now" so the watch's hourly screen has a bucket for
        // the current hour — without it the watch falls back to "waiting for
        // data". Drop only entries whose window has fully elapsed. Encoder
        // caps at 12; respect the watch's requested horizon if it's smaller.
        let calendar = Calendar.current
        let hourLimit = min(12, max(1, Int(request.hoursOfForecast)))
        let hourly: [GarminHourlyForecast] = weather.hourlyForecast.forecast
            .filter { $0.date.addingTimeInterval(3600) > now }
            .prefix(hourLimit)
            .map { h in
                GarminHourlyForecast(
                    timestamp: garminTimestamp(from: h.date),
                    temperature: celsiusInt8(h.temperature),
                    condition: mapCondition(h.condition),
                    precipitationProbability: percentUInt8(h.precipitationChance),
                    dayOfWeek: Self.dayOfWeek(for: h.date, in: calendar)
                )
            }

        let daily: [GarminDailyForecast] = weather.dailyForecast.forecast.prefix(5).map { d in
            GarminDailyForecast(
                timestamp: garminTimestamp(from: d.date),
                lowTemperature: celsiusInt8(d.lowTemperature),
                highTemperature: celsiusInt8(d.highTemperature),
                condition: mapCondition(d.condition),
                precipitationProbability: percentUInt8(d.precipitationChance),
                dayOfWeek: Self.dayOfWeek(for: d.date, in: calendar)
            )
        }

        AppLogger.services.info(
            "Weather: built — \(Self.summary(current: current, hourly: hourly, daily: daily, now: now))"
        )
        for line in Self.detailedLines(current: current, hourly: hourly, daily: daily) {
            AppLogger.services.info("Weather:   \(line)")
        }
        return WeatherFITEncoder.encode(current: current, hourly: hourly, daily: daily)
    }

    // MARK: - Logging helpers

    private static func summary(
        current: GarminCurrentConditions,
        hourly: [GarminHourlyForecast],
        daily: [GarminDailyForecast],
        now: Date
    ) -> String {
        let cond = Self.conditionName(current.condition)
        return "now \(current.temperature)°C \(cond)(\(current.condition)) + \(hourly.count)h \(daily.count)d "
             + "first-hourly=\(hourly.first.map { Self.relTime($0.timestamp, now: now) } ?? "—")"
    }

    private static func detailedLines(
        current: GarminCurrentConditions,
        hourly: [GarminHourlyForecast],
        daily: [GarminDailyForecast]
    ) -> [String] {
        var lines: [String] = []
        lines.append(
            "current: ts=\(time(current.timestamp)) "
          + "obs=\(time(current.observedAtTime)) "
          + "\(current.temperature)°C lo=\(current.lowTemperature) hi=\(current.highTemperature) "
          + "\(conditionName(current.condition))(\(current.condition)) "
          + "wind=\(current.windDirection)°@\(windSpeedKmh(current.windSpeed)) "
          + "precip=\(current.precipitationProbability)% feels=\(current.temperatureFeelsLike) "
          + "humid=\(current.relativeHumidity)%"
        )
        if hourly.isEmpty {
            lines.append("hourly: (none)")
        } else {
            lines.append("hourly[\(hourly.count)]:")
            for (i, h) in hourly.enumerated() {
                lines.append(
                    String(format: "  [%2d] ", i)
                  + "\(time(h.timestamp)) \(dayName(h.dayOfWeek)) "
                  + "\(h.temperature)°C \(conditionName(h.condition))(\(h.condition)) "
                  + "precip=\(h.precipitationProbability)%"
                )
            }
        }
        if daily.isEmpty {
            lines.append("daily: (none)")
        } else {
            lines.append("daily[\(daily.count)]:")
            for (i, d) in daily.enumerated() {
                lines.append(
                    String(format: "  [%d] ", i)
                  + "\(date(d.timestamp)) \(dayName(d.dayOfWeek)) "
                  + "\(d.lowTemperature)–\(d.highTemperature)°C "
                  + "\(conditionName(d.condition))(\(d.condition)) "
                  + "precip=\(d.precipitationProbability)%"
                )
            }
        }
        return lines
    }

    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static let logDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func time(_ garmin: UInt32) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(garmin) + garminEpochOffset)
        return logTimeFormatter.string(from: d)
    }

    private static func date(_ garmin: UInt32) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(garmin) + garminEpochOffset)
        return logDateFormatter.string(from: d)
    }

    private static func relTime(_ garmin: UInt32, now: Date) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(garmin) + garminEpochOffset)
        let delta = Int(d.timeIntervalSince(now).rounded())
        let sign = delta >= 0 ? "+" : "-"
        let abs = Swift.abs(delta)
        if abs < 60 { return "\(time(garmin)) (now\(sign)\(abs)s)" }
        let m = abs / 60
        return "\(time(garmin)) (now\(sign)\(m)m)"
    }

    private static func windSpeedKmh(_ mmPerSec: UInt16) -> String {
        // Watch wants mm/s; logs read better in km/h.
        let kmh = Double(mmPerSec) * 3.6 / 1000
        return String(format: "%.1fkm/h", kmh)
    }

    private static func dayName(_ dow: UInt8) -> String {
        switch dow {
        case 0: return "Sun"; case 1: return "Mon"; case 2: return "Tue"
        case 3: return "Wed"; case 4: return "Thu"; case 5: return "Fri"
        case 6: return "Sat"
        default: return "?\(dow)"
        }
    }

    /// Names mirror Garmin's `weather_status` enum
    /// (`rzfit_swift_map.swift:3840-3866`). Stays in sync with `mapCondition`.
    private static func conditionName(_ code: UInt8) -> String {
        switch code {
        case 0:  return "clear"
        case 1:  return "partly_cloudy"
        case 2:  return "mostly_cloudy"
        case 3:  return "rain"
        case 4:  return "snow"
        case 5:  return "windy"
        case 6:  return "thunderstorms"
        case 7:  return "wintry_mix"
        case 8:  return "fog"
        case 11: return "hazy"
        case 12: return "hail"
        case 13: return "scattered_showers"
        case 14: return "scattered_thunderstorms"
        case 15: return "unknown_precipitation"
        case 16: return "light_rain"
        case 17: return "heavy_rain"
        case 18: return "light_snow"
        case 19: return "heavy_snow"
        case 20: return "light_rain_snow"
        case 21: return "heavy_rain_snow"
        case 22: return "cloudy"
        default: return "?\(code)"
        }
    }

    // MARK: - Conversions

    private func celsiusInt8(_ measurement: Measurement<UnitTemperature>) -> Int8 {
        Int8(clamping: Int(measurement.converted(to: .celsius).value.rounded()))
    }

    private func degreesUInt16(_ measurement: Measurement<UnitAngle>) -> UInt16 {
        let degrees = Int(measurement.converted(to: .degrees).value.rounded())
        return UInt16(max(0, min(359, degrees)))
    }

    private func windSpeedMillimetersPerSecond(_ measurement: Measurement<UnitSpeed>) -> UInt16 {
        let mmPerSec = measurement.converted(to: .metersPerSecond).value * 1000
        return UInt16(max(0, min(Double(UInt16.max), mmPerSec.rounded())))
    }

    private func percentUInt8(_ fraction: Double) -> UInt8 {
        UInt8(max(0, min(100, Int((fraction * 100).rounded()))))
    }

    // Garmin semicircles: int = degrees × (2^31 / 180)
    private func semicircles(from coordinate: CLLocationCoordinate2D) -> (Int32, Int32) {
        let scale = pow(2.0, 31.0) / 180.0
        let lat = Int32(clamping: Int((coordinate.latitude  * scale).rounded()))
        let lon = Int32(clamping: Int((coordinate.longitude * scale).rounded()))
        return (lat, lon)
    }

    /// Maps a WeatherKit `WeatherCondition` to Garmin's `weather_status` enum,
    /// authoritative table at `rzfit_swift_map.swift:3840-3866`:
    ///   0=clear, 1=partly_cloudy, 2=mostly_cloudy, 3=rain, 4=snow, 5=windy,
    ///   6=thunderstorms, 7=wintry_mix, 8=fog, 11=hazy, 12=hail,
    ///   13=scattered_showers, 14=scattered_thunderstorms, 15=unknown_precip,
    ///   16=light_rain, 17=heavy_rain, 18=light_snow, 19=heavy_snow,
    ///   20=light_rain_snow, 21=heavy_rain_snow, 22=cloudy.
    private func mapCondition(_ condition: WeatherCondition) -> UInt8 {
        switch condition {
        case .clear, .mostlyClear, .hot, .frigid:                       return 0
        case .partlyCloudy:                                             return 1
        case .mostlyCloudy:                                             return 2
        case .cloudy:                                                   return 22
        case .drizzle, .freezingDrizzle:                                return 16   // light_rain
        case .rain, .freezingRain:                                      return 3    // rain
        case .heavyRain:                                                return 17   // heavy_rain
        case .sunShowers:                                               return 13   // scattered_showers
        case .flurries:                                                 return 18   // light_snow
        case .snow:                                                     return 4    // snow
        case .heavySnow, .blizzard, .blowingSnow:                       return 19   // heavy_snow
        case .sunFlurries:                                              return 18   // light_snow (best fit)
        case .sleet, .wintryMix:                                        return 7    // wintry_mix
        case .hail:                                                     return 12   // hail
        case .isolatedThunderstorms, .scatteredThunderstorms:           return 14   // scattered_thunderstorms
        case .thunderstorms, .strongStorms, .tropicalStorm, .hurricane: return 6    // thunderstorms
        case .foggy:                                                    return 8    // fog
        case .haze, .smoky, .blowingDust:                               return 11   // hazy
        case .breezy, .windy:                                           return 5    // windy
        @unknown default:                                               return 0
        }
    }

    /// Garmin's `day_of_week` enum: 0=Sun…6=Sat. Apple's `Calendar.weekday`
    /// is 1=Sun…7=Sat, so subtract one (the `+7 % 7` is a safety net for any
    /// locale that ever flips the start of week).
    private static func dayOfWeek(for date: Date, in calendar: Calendar) -> UInt8 {
        UInt8((calendar.component(.weekday, from: date) - 1 + 7) % 7)
    }

    private func garminTimestamp(from date: Date) -> UInt32 {
        let unix = date.timeIntervalSince1970 - Self.garminEpochOffset
        return UInt32(max(0, unix))
    }
}

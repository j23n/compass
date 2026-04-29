import Foundation
import CompassBLE

/// Encodes weather data as inline FIT messages for the watch in response to
/// WEATHER_REQUEST.
///
/// STUB: WeatherKit integration is written but gated behind a compile flag
/// because the `com.apple.developer.weatherkit` entitlement requires Apple
/// approval.  Until it is provisioned this service returns plausible example
/// data so the watch receives a valid weather response and stops retransmitting.
///
/// To enable real weather:
///   1. Add `com.apple.developer.weatherkit: true` to Compass.entitlements.
///   2. Enable WeatherKit in your App ID on developer.apple.com.
///   3. Replace the stub body of `buildFITMessages` with the WeatherKit
///      implementation preserved in the comment block below.
@MainActor
final class WeatherService {

    private static let garminEpochOffset: TimeInterval = 631_065_600

    func buildFITMessages(for request: WeatherRequest) async throws -> [GFDIMessage] {
        let current = stubCurrent(for: request)
        let hourly  = stubHourly(count: 12, from: request)
        let daily   = stubDaily(count: 5,   from: request)
        AppLogger.services.info(
            "Weather (stub): \(current.temperature)°C cond=\(current.condition) + \(hourly.count)h \(daily.count)d forecast"
        )
        return WeatherFITEncoder.encode(current: current, hourly: hourly, daily: daily)
    }

    // MARK: - Stub

    private func stubCurrent(for request: WeatherRequest) -> GarminCurrentConditions {
        let now = garminTimestamp(from: Date())
        let (lat, lon) = clampedCoords(from: request)
        return GarminCurrentConditions(
            timestamp: now,
            observedAtTime: now,
            temperature: 18,
            lowTemperature: 12,
            highTemperature: 22,
            condition: 1,         // partly cloudy
            windDirection: 270,
            precipitationProbability: 20,
            windSpeed: 5000,      // 5 m/s in mm/s
            temperatureFeelsLike: 16,
            relativeHumidity: 60,
            observedLocationLat: lat,
            observedLocationLong: lon,
            location: ""
        )
    }

    private func stubHourly(count: Int, from request: WeatherRequest) -> [GarminHourlyForecast] {
        let now = Date()
        let conditions: [UInt8] = [1,  1,  0,  0, 13, 13,  5,  5,  1,  1,  0,  0]
        let temps:      [Int8]  = [18, 19, 20, 21, 20, 18, 17, 16, 17, 18, 19, 20]
        let precips:    [UInt8] = [20, 15, 10,  5, 25, 40, 60, 50, 30, 20, 10,  5]

        return (0..<count).map { offset in
            let date = Date(timeIntervalSince1970: now.timeIntervalSince1970 + Double(offset + 1) * 3600)
            let idx = offset % conditions.count
            return GarminHourlyForecast(
                timestamp: garminTimestamp(from: date),
                temperature: temps[idx],
                condition: conditions[idx],
                windDirection: 270,
                windSpeed: 4000,
                precipitationProbability: precips[idx],
                temperatureFeelsLike: Int8(clamping: Int(temps[idx]) - 2),
                relativeHumidity: 58
            )
        }
    }

    private func stubDaily(count: Int, from request: WeatherRequest) -> [GarminDailyForecast] {
        let calendar = Calendar.current
        let today = Date()
        let conditions: [UInt8] = [1,  0,  13,  5,  0]
        let highs:      [Int8]  = [22, 24,  19, 17, 21]
        let lows:       [Int8]  = [12, 14,  12, 11, 13]
        let precips:    [UInt8] = [20,  5,  30, 70, 15]

        // Day 0 = today's daily summary, days 1-4 = future days (matches Gadgetbridge).
        return (0..<count).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: today)!
            let weekday = UInt8((calendar.component(.weekday, from: date) - 1 + 7) % 7)
            let idx = offset % conditions.count
            return GarminDailyForecast(
                timestamp: garminTimestamp(from: date),
                lowTemperature: lows[idx],
                highTemperature: highs[idx],
                condition: conditions[idx],
                precipitationProbability: precips[idx],
                dayOfWeek: weekday
            )
        }
    }

    // If the watch has no GPS fix it sends 0x7FFFFFFF (FIT invalid sentinel).
    // Return 0,0 so the watch doesn't discard the weather record.
    private func clampedCoords(from request: WeatherRequest) -> (Int32, Int32) {
        (
            request.latitudeSemicircles  == Int32.max ? 0 : request.latitudeSemicircles,
            request.longitudeSemicircles == Int32.max ? 0 : request.longitudeSemicircles
        )
    }

    private func garminTimestamp(from date: Date) -> UInt32 {
        let unix = date.timeIntervalSince1970 - Self.garminEpochOffset
        return UInt32(max(0, unix))
    }
}

/*
 WeatherKit implementation — restore this when the entitlement is active.
 Requires: import WeatherKit, import CoreLocation

 func buildFITMessages(for request: WeatherRequest) async throws -> [GFDIMessage] {
     let location = CLLocation(latitude: request.latitude, longitude: request.longitude)
     let weather = try await WeatherKit.WeatherService.shared.weather(
         for: location,
         including: .current, .hourlyForecast, .dailyForecast
     )
     let (lat, lon) = clampedCoords(from: request)
     let now = garminTimestamp(from: Date())

     let current = GarminCurrentConditions(
         timestamp: now,
         observedAtTime: now,
         temperature: Int8(clamping: Int(weather.currentWeather.temperature.converted(to: .celsius).value)),
         lowTemperature: Int8(clamping: Int((weather.dailyForecast.first?.lowTemperature.converted(to: .celsius).value ?? 0))),
         highTemperature: Int8(clamping: Int((weather.dailyForecast.first?.highTemperature.converted(to: .celsius).value ?? 0))),
         condition: mapCondition(weather.currentWeather.condition),
         windDirection: UInt16(max(0, min(359, Int(weather.currentWeather.wind.direction.value)))),
         precipitationProbability: UInt8(max(0, min(100, Int((weather.dailyForecast.first?.precipitationChance ?? 0) * 100)))),
         windSpeed: UInt16(max(0, min(65535, Int(weather.currentWeather.wind.speed.converted(to: .metersPerSecond).value * 1000)))),
         temperatureFeelsLike: Int8(clamping: Int(weather.currentWeather.apparentTemperature.converted(to: .celsius).value)),
         relativeHumidity: UInt8(max(0, min(100, Int(weather.currentWeather.humidity * 100)))),
         observedLocationLat: lat,
         observedLocationLong: lon,
         location: ""
     )

     let hourly: [GarminHourlyForecast] = weather.hourlyForecast.prefix(12).map { h in
         GarminHourlyForecast(
             timestamp: garminTimestamp(from: h.date),
             temperature: Int8(clamping: Int(h.temperature.converted(to: .celsius).value)),
             condition: mapCondition(h.condition),
             windDirection: UInt16(max(0, min(359, Int(h.wind.direction.value)))),
             windSpeed: UInt16(max(0, min(65535, Int(h.wind.speed.converted(to: .metersPerSecond).value * 1000)))),
             precipitationProbability: UInt8(max(0, min(100, Int(h.precipitationChance * 100)))),
             temperatureFeelsLike: Int8(clamping: Int(h.apparentTemperature.converted(to: .celsius).value)),
             relativeHumidity: UInt8(max(0, min(100, Int(h.humidity * 100))))
         )
     }

     let calendar = Calendar.current
     let daily: [GarminDailyForecast] = weather.dailyForecast.prefix(5).map { d in
         let weekday = UInt8((calendar.component(.weekday, from: d.date) - 1 + 7) % 7)
         return GarminDailyForecast(
             timestamp: garminTimestamp(from: d.date),
             lowTemperature: Int8(clamping: Int(d.lowTemperature.converted(to: .celsius).value)),
             highTemperature: Int8(clamping: Int(d.highTemperature.converted(to: .celsius).value)),
             condition: mapCondition(d.condition),
             precipitationProbability: UInt8(max(0, min(100, Int(d.precipitationChance * 100)))),
             dayOfWeek: weekday
         )
     }

     AppLogger.services.info(
         "Weather: \(current.temperature)°C cond=\(current.condition) + \(hourly.count)h \(daily.count)d"
     )
     return WeatherFITEncoder.encode(current: current, hourly: hourly, daily: daily)
 }

 private func mapCondition(_ condition: WeatherCondition) -> UInt8 {
     switch condition {
     case .clear, .mostlyClear, .hot, .frigid:                                    return 0
     case .partlyCloudy, .sunShowers, .sunFlurries:                               return 1
     case .mostlyCloudy:                                                          return 3
     case .cloudy:                                                                return 13
     case .drizzle, .freezingDrizzle, .rain, .heavyRain, .freezingRain:          return 5
     case .snow, .heavySnow, .flurries, .blizzard, .blowingSnow, .sleet,
          .wintryMix, .hail:                                                      return 6
     case .thunderstorms, .scatteredThunderstorms, .isolatedThunderstorms,
          .strongStorms, .tropicalStorm, .hurricane:                              return 15
     case .foggy, .haze, .smoky, .blowingDust:                                   return 8
     case .breezy, .windy:                                                        return 7
     @unknown default:                                                            return 0
     }
 }
*/

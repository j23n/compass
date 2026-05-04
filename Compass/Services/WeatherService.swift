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
        // (e.g. 12:00 even when now is 12:34). The watch filters out forecasts
        // whose timestamp is in the past, so drop past hours first. Encoder
        // caps at 12; respect the watch's requested horizon if it's smaller.
        let hourLimit = min(12, max(1, Int(request.hoursOfForecast)))
        let hourly: [GarminHourlyForecast] = weather.hourlyForecast.forecast
            .filter { $0.date > now }
            .prefix(hourLimit)
            .map { h in
                GarminHourlyForecast(
                    timestamp: garminTimestamp(from: h.date),
                    temperature: celsiusInt8(h.temperature),
                    condition: mapCondition(h.condition),
                    windDirection: degreesUInt16(h.wind.direction),
                    windSpeed: windSpeedMillimetersPerSecond(h.wind.speed),
                    precipitationProbability: percentUInt8(h.precipitationChance),
                    temperatureFeelsLike: celsiusInt8(h.apparentTemperature),
                    relativeHumidity: percentUInt8(h.humidity)
                )
            }

        let calendar = Calendar.current
        let daily: [GarminDailyForecast] = weather.dailyForecast.forecast.prefix(5).map { d in
            let weekday = UInt8((calendar.component(.weekday, from: d.date) - 1 + 7) % 7)
            return GarminDailyForecast(
                timestamp: garminTimestamp(from: d.date),
                lowTemperature: celsiusInt8(d.lowTemperature),
                highTemperature: celsiusInt8(d.highTemperature),
                condition: mapCondition(d.condition),
                precipitationProbability: percentUInt8(d.precipitationChance),
                dayOfWeek: weekday
            )
        }

        AppLogger.services.info(
            "Weather: \(current.temperature)°C cond=\(current.condition) + \(hourly.count)h \(daily.count)d"
        )
        return WeatherFITEncoder.encode(current: current, hourly: hourly, daily: daily)
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

    private func mapCondition(_ condition: WeatherCondition) -> UInt8 {
        switch condition {
        case .clear, .mostlyClear, .hot, .frigid:                                    return 0
        case .partlyCloudy, .sunShowers, .sunFlurries:                               return 1
        case .mostlyCloudy:                                                          return 3
        case .cloudy:                                                                return 13
        case .drizzle, .freezingDrizzle, .rain, .heavyRain, .freezingRain:           return 5
        case .snow, .heavySnow, .flurries, .blizzard, .blowingSnow, .sleet,
             .wintryMix, .hail:                                                      return 6
        case .thunderstorms, .scatteredThunderstorms, .isolatedThunderstorms,
             .strongStorms, .tropicalStorm, .hurricane:                              return 15
        case .foggy, .haze, .smoky, .blowingDust:                                    return 8
        case .breezy, .windy:                                                        return 7
        @unknown default:                                                            return 0
        }
    }

    private func garminTimestamp(from date: Date) -> UInt32 {
        let unix = date.timeIntervalSince1970 - Self.garminEpochOffset
        return UInt32(max(0, unix))
    }
}

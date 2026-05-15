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
        let buildVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber  = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        AppLogger.services.info(
            "WeatherService.buildFITMessages: build=\(buildVersion)(\(buildNumber)) "
          + "request=hours\(request.hoursOfForecast) lat=\(String(format: "%.4f", request.latitude)) "
          + "lon=\(String(format: "%.4f", request.longitude))"
        )
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
            windSpeed: windSpeedKmPerHour(weather.currentWeather.wind.speed),
            temperatureFeelsLike: celsiusInt8(weather.currentWeather.apparentTemperature),
            relativeHumidity: percentUInt8(weather.currentWeather.humidity),
            observedLocationLat: lat,
            observedLocationLong: lon,
            location: ""
        )

        // WeatherKit's hourly forecast starts at the top of the *current* hour
        // (e.g. 12:00 even when now is 12:34). Keep entries whose hour-bucket
        // hasn't ended yet — i.e. include the current hour as the anchor the
        // watch's hourly widget aligns its strip to. Earlier we filtered strictly
        // `> now`, leaving only future hours; the widget then sat on
        // "waiting for data" because it lacked a current-hour record. Encoder
        // caps at 12; respect the watch's requested horizon if it's smaller.
        let hourLimit = min(12, max(1, Int(request.hoursOfForecast)))
        let rawForecasts = weather.hourlyForecast.forecast
        let currentHourCutoff = now.addingTimeInterval(-3600)
        let usableForecasts = rawForecasts.filter { $0.date > currentHourCutoff }
        let firstRawDate = rawForecasts.first?.date.formatted(date: .omitted, time: .shortened) ?? "n/a"
        let firstUsableDate = usableForecasts.first?.date.formatted(date: .omitted, time: .shortened) ?? "n/a"
        AppLogger.services.info(
            "Weather: hourly filter — raw=\(rawForecasts.count) firstRaw=\(firstRawDate) "
          + "usable=\(usableForecasts.count) firstUsable=\(firstUsableDate) "
          + "limit=\(hourLimit) now=\(now.formatted(date: .omitted, time: .shortened))"
        )
        let hourly: [GarminHourlyForecast] = usableForecasts
            .prefix(hourLimit)
            .map { h in
                GarminHourlyForecast(
                    timestamp: garminTimestamp(from: h.date),
                    temperature: celsiusInt8(h.temperature),
                    condition: mapCondition(h.condition),
                    windDirection: degreesUInt16(h.wind.direction),
                    windSpeed: windSpeedKmPerHour(h.wind.speed),
                    precipitationProbability: percentUInt8(h.precipitationChance),
                    temperatureFeelsLike: celsiusInt8(h.apparentTemperature),
                    relativeHumidity: percentUInt8(h.humidity),
                    uvIndex: Float(max(0, h.uvIndex.value))
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

    private func windSpeedKmPerHour(_ measurement: Measurement<UnitSpeed>) -> UInt16 {
        // The FIT SDK profile says wind_speed is mm/s, but Garmin firmware
        // actually interprets the field as km/h — Gadgetbridge had the same
        // bug (fixed in 0.81 "Fix weather temperature and speed units",
        // issue #3836: values were being sent as m/s but the watch was
        // interpreting them as km/h, so wind speeds came out 3.6x high).
        // Sending mm/s here meant our values were ~3600x what the watch
        // expected, which is plausibly why the hourly widget rejected the
        // records and sat on "waiting for data".
        let kmPerHour = measurement.converted(to: .kilometersPerHour).value
        return UInt16(max(0, min(Double(UInt16.max), kmPerHour.rounded())))
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

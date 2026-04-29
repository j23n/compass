import Foundation

/// Parsed WEATHER_REQUEST from the watch (5014 / 0x1396).
///
/// The watch sends this every ~5 s when weather is enabled; the phone should
/// respond with a FIT_DEFINITION + FIT_DATA pair carrying a weather_conditions
/// record.  Coordinates arrive in Garmin semicircles; use `latitude` /
/// `longitude` for WeatherKit queries.
public struct WeatherRequest: Sendable {
    /// Raw format byte from the watch payload.
    public let format: UInt8
    /// Latitude in Garmin semicircles (Int32, two's-complement LE).
    public let latitudeSemicircles: Int32
    /// Longitude in Garmin semicircles.
    public let longitudeSemicircles: Int32
    /// How many hours of forecast the watch wants.
    public let hoursOfForecast: UInt8

    public init(
        format: UInt8,
        latitudeSemicircles: Int32,
        longitudeSemicircles: Int32,
        hoursOfForecast: UInt8
    ) {
        self.format = format
        self.latitudeSemicircles = latitudeSemicircles
        self.longitudeSemicircles = longitudeSemicircles
        self.hoursOfForecast = hoursOfForecast
    }

    // Semicircles → degrees: degrees = semicircles × (180 / 2^31)
    private static let semicirclesToDegrees: Double = 180.0 / pow(2.0, 31.0)

    public var latitude: Double {
        Double(latitudeSemicircles) * Self.semicirclesToDegrees
    }
    public var longitude: Double {
        Double(longitudeSemicircles) * Self.semicirclesToDegrees
    }
}

/// Event fired by the watch's Find My Phone feature (5039 / 0x13AF and 5040 / 0x13B0).
public enum FindMyPhoneEvent: Sendable {
    case started
    case cancelled
}

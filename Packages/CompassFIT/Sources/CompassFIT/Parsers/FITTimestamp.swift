import Foundation

/// Utilities for converting FIT timestamps to Foundation `Date` values.
///
/// FIT timestamps are seconds since 1989-12-31T00:00:00Z (the "Garmin epoch").
public enum FITTimestamp: Sendable {

    /// The Garmin/FIT epoch: 1989-12-31 00:00:00 UTC.
    /// All FIT `date_time` fields are seconds since this reference date.
    public static let epoch: Date = {
        var components = DateComponents()
        components.year = 1989
        components.month = 12
        components.day = 31
        components.hour = 0
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    /// Converts a FIT `date_time` field value (seconds since Garmin epoch) to a `Date`.
    public static func date(fromFITTimestamp timestamp: UInt32) -> Date {
        epoch.addingTimeInterval(TimeInterval(timestamp))
    }

    /// Converts a `FITFieldValue` to a `Date` if it contains a numeric timestamp.
    public static func date(from value: FITFieldValue) -> Date? {
        guard let ts = value.uint32Value else { return nil }
        return date(fromFITTimestamp: ts)
    }
}

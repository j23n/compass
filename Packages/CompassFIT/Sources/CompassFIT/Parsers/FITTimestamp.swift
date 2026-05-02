import Foundation

/// Utilities for converting FIT timestamps to Foundation `Date` values.
///
/// FIT timestamps are seconds since 1989-12-31T00:00:00Z (the "Garmin epoch").
public enum FITTimestamp: Sendable {

    /// The Garmin/FIT epoch: 1989-12-31 00:00:00 UTC.
    public static let epoch: Date = {
        var components = DateComponents()
        components.year = 1989
        components.month = 12
        components.day = 31
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    /// Converts a FIT `date_time` field value (seconds since Garmin epoch) to a `Date`.
    public static func date(fromFITTimestamp timestamp: UInt32) -> Date {
        epoch.addingTimeInterval(TimeInterval(timestamp))
    }
}

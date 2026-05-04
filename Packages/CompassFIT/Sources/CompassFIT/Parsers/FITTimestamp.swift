import Foundation
import FitFileParser

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

    /// Lower bound on a plausible FIT timestamp value: roughly year 2000.
    /// Used to distinguish a Garmin-epoch seconds count from a small UINT32 that
    /// happens to live in field 253 of a custom message we don't fully type.
    private static let minPlausibleSeconds: UInt32 = 315532800 // ~10 years post-epoch

    /// Converts a FIT `date_time` field value (seconds since Garmin epoch) to a `Date`.
    public static func date(fromFITTimestamp timestamp: UInt32) -> Date {
        epoch.addingTimeInterval(TimeInterval(timestamp))
    }

    /// Resolves the `timestamp` field from a `FitMessage` to a `Date`, working around
    /// custom message types in our augmented profile where the date flag is missing
    /// (so the Obj-C interpreter stores the value as a plain UINT32 rather than a Date).
    ///
    /// Tries:
    /// 1. The native `.time` interpretation (works for SDK-defined messages).
    /// 2. Falls back to reading the field as a UINT32 and converting via the Garmin epoch
    ///    when it's large enough to plausibly be a date_time.
    public static func resolve(_ message: FitMessage, key: String = "timestamp") -> Date? {
        if let date = message.interpretedField(key: key)?.time {
            return date
        }
        let fv = message.interpretedField(key: key)
        if let raw = fv?.value ?? fv?.valueUnit?.value, raw >= Double(minPlausibleSeconds) {
            return date(fromFITTimestamp: UInt32(raw))
        }
        return nil
    }
}

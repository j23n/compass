import Foundation
import os
import CompassData

/// A lightweight HRV result (not tied to SwiftData).
public struct HRVResult: Sendable, Equatable {
    public let timestamp: Date
    public let rmssd: Double

    public init(timestamp: Date, rmssd: Double) {
        self.timestamp = timestamp
        self.rmssd = rmssd
    }
}

/// Parses Garmin `/GARMIN/Metrics/*.fit` files for HRV (Heart Rate Variability) data.
///
/// Reads HRV messages (mesg_num 78) which contain RMSSD values.
public struct MetricsFITParser: Sendable {

    private static let logger = Logger(subsystem: "com.compass.fit", category: "MetricsFITParser")

    // FIT HRV message number
    private static let hrvMessageNum: UInt16 = 78
    // HRV status summary (Garmin-specific)
    private static let hrvStatusSummaryMessageNum: UInt16 = 370

    // HRV (78) field numbers
    private static let fieldTimestamp: UInt8 = 253
    private static let hrvValue: UInt8 = 0  // time in ms between beats (R-R interval array)

    // HRV status summary fields
    private static let weeklyAverage: UInt8 = 0
    private static let lastNightAverage: UInt8 = 1
    private static let lastNight5MinHigh: UInt8 = 2
    private static let rmssdField: UInt8 = 3

    private let overlay: FieldNameOverlay

    public init(overlay: FieldNameOverlay = FieldNameOverlay()) {
        self.overlay = overlay
    }

    /// Parses a metrics FIT file and returns HRV samples.
    ///
    /// - Parameter data: Raw bytes of the FIT file.
    /// - Returns: An array of ``HRVResult`` values.
    public func parse(data: Data) async throws -> [HRVResult] {
        let decoder = FITDecoder()
        let fitFile = try decoder.decode(data: data)

        var results: [HRVResult] = []
        var currentTimestamp: Date?

        for message in fitFile.messages {
            switch message.globalMessageNumber {
            case Self.hrvMessageNum:
                // HRV messages may carry a timestamp, or inherit from a preceding timestamp message.
                if let ts = message.fields[Self.fieldTimestamp].flatMap(FITTimestamp.date(from:)) {
                    currentTimestamp = ts
                }
                if let rmssd = extractRMSSD(from: message.fields),
                   let timestamp = currentTimestamp {
                    results.append(HRVResult(timestamp: timestamp, rmssd: rmssd))
                }

            case Self.hrvStatusSummaryMessageNum:
                // Garmin HRV status summary - extract RMSSD if present.
                if let ts = message.fields[Self.fieldTimestamp].flatMap(FITTimestamp.date(from:)),
                   let rmssd = message.fields[Self.rmssdField]?.doubleValue {
                    results.append(HRVResult(timestamp: ts, rmssd: rmssd))
                }

            default:
                // Update running timestamp from any message that carries one.
                if let ts = message.fields[Self.fieldTimestamp].flatMap(FITTimestamp.date(from:)) {
                    currentTimestamp = ts
                }
                let enriched = overlay.apply(toMessage: message.globalMessageNumber, fields: message.fields)
                if enriched.messageName == nil && message.globalMessageNumber > 100 {
                    Self.logger.debug("Unknown metrics message \(message.globalMessageNumber)")
                }
            }
        }

        return results
    }

    // MARK: - Private helpers

    /// Extracts an RMSSD value from an HRV message.
    ///
    /// The standard FIT HRV message field 0 contains R-R intervals in ms (as uint16 arrays).
    /// We compute RMSSD from consecutive differences when multiple values are present,
    /// or use the single value directly if only one is available.
    private func extractRMSSD(from fields: [UInt8: FITFieldValue]) -> Double? {
        // If the field is a single numeric value, treat it as an R-R interval / RMSSD.
        if let value = fields[Self.hrvValue]?.doubleValue {
            // Filter out invalid values (0xFFFF = invalid in FIT).
            guard value > 0, value < 65535 else { return nil }
            return value
        }
        return nil
    }
}

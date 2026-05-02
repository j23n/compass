import Foundation
import os
import FitFileParser
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

/// Parses Garmin `/GARMIN/Metrics/*.fit` files for HRV data.
///
/// - hrv (78): per-beat R-R intervals (seconds, scale already applied). One sample per record.
/// - hrv_status_summary (370): nightly HRV stats; we use `last_night_average` (ms).
public struct MetricsFITParser: Sendable {

    private static let logger = Logger(subsystem: "com.compass.fit", category: "MetricsFITParser")

    public init() {}

    public func parse(data: Data) async throws -> [HRVResult] {
        let fitFile = FitFile(data: data, parsingType: .generic)

        var results: [HRVResult] = []
        var currentTimestamp: Date?

        for message in fitFile.messages {
            switch message.messageType {
            case .hrv:
                // hrv (78) has no timestamp field; inherits from preceding messages.
                if let rr = extractRRInterval(from: message), let ts = currentTimestamp {
                    results.append(HRVResult(timestamp: ts, rmssd: rr))
                }

            case .hrv_status_summary:
                if let ts = message.interpretedField(key: "timestamp")?.time,
                   let avg = message.interpretedField(key: "last_night_average")?.value
                            ?? message.interpretedField(key: "last_night_average")?.valueUnit?.value {
                    results.append(HRVResult(timestamp: ts, rmssd: avg))
                }

            default:
                if let ts = message.interpretedField(key: "timestamp")?.time {
                    currentTimestamp = ts
                }
            }
        }

        return results
    }

    // MARK: - Private helpers

    /// Extracts a single R-R interval (seconds) from an hrv message.
    /// `time` is a pipe-delimited array via `.name`; fall back to `.value` for scalar.
    private func extractRRInterval(from message: FitMessage) -> Double? {
        let fv = message.interpretedField(key: "time")
        if let str = fv?.name {
            for piece in str.split(separator: "|") {
                if let v = Double(piece), (0.3...2.0).contains(v) {
                    return v
                }
            }
            return nil
        }
        if let v = fv?.value, (0.3...2.0).contains(v) {
            return v
        }
        return nil
    }
}

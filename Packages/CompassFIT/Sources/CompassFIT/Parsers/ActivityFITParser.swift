import Foundation
import os
import CompassData

/// Parses Garmin `/GARMIN/Activity/*.fit` files into `Activity` and `TrackPoint` models.
///
/// Reads:
/// - Session messages (mesg_num 18) for activity summary data
/// - Record messages (mesg_num 20) for GPS track points
/// - Lap messages (mesg_num 19) for lap information
public struct ActivityFITParser: Sendable {

    private static let logger = Logger(subsystem: "com.compass.fit", category: "ActivityFITParser")

    // FIT global message numbers
    private static let sessionMessageNum: UInt16 = 18
    private static let lapMessageNum: UInt16 = 19
    private static let recordMessageNum: UInt16 = 20

    // Common FIT field definition numbers for session (18)
    private static let fieldTimestamp: UInt8 = 253
    private static let fieldStartTime: UInt8 = 2
    private static let fieldTotalElapsedTime: UInt8 = 7   // in ms (scale 1000)
    private static let fieldTotalDistance: UInt8 = 5       // in cm (scale 100)
    private static let fieldTotalCalories: UInt8 = 11      // kcal
    private static let fieldAvgHeartRate: UInt8 = 16
    private static let fieldMaxHeartRate: UInt8 = 17
    private static let fieldTotalAscent: UInt8 = 22        // meters
    private static let fieldTotalDescent: UInt8 = 23       // meters
    private static let fieldSport: UInt8 = 5               // sport enum field in session
    private static let fieldSessionSport: UInt8 = 5

    // Record (20) field definition numbers
    private static let recordTimestamp: UInt8 = 253
    private static let recordLatitude: UInt8 = 0           // semicircles
    private static let recordLongitude: UInt8 = 1          // semicircles
    private static let recordAltitude: UInt8 = 2           // scale 5, offset 500
    private static let recordHeartRate: UInt8 = 3          // bpm
    private static let recordCadence: UInt8 = 4
    private static let recordSpeed: UInt8 = 6              // scale 1000 m/s
    private static let recordTemperature: UInt8 = 13       // degrees C

    /// Semicircles to degrees conversion factor.
    private static let semicirclesToDegrees: Double = 180.0 / Double(Int64(1) << 31)

    private let overlay: FieldNameOverlay

    public init(overlay: FieldNameOverlay = FieldNameOverlay()) {
        self.overlay = overlay
    }

    /// Parses a FIT activity file and returns an `Activity` with associated `TrackPoint`s.
    ///
    /// - Parameter data: Raw bytes of the FIT file.
    /// - Returns: A populated `Activity`, or `nil` if no session was found.
    public func parse(data: Data) async throws -> Activity? {
        let decoder = FITDecoder()
        let fitFile = try decoder.decode(data: data)

        var sessionFields: [UInt8: FITFieldValue]?
        var trackPoints: [TrackPoint] = []

        for message in fitFile.messages {
            switch message.globalMessageNumber {
            case Self.sessionMessageNum:
                // Take the first session message.
                if sessionFields == nil {
                    sessionFields = message.fields
                }

            case Self.recordMessageNum:
                if let tp = parseTrackPoint(from: message.fields) {
                    trackPoints.append(tp)
                }

            case Self.lapMessageNum:
                // Lap data is available but not mapped to CompassData models yet.
                Self.logger.debug("Lap message found; not yet mapped.")

            default:
                let enriched = overlay.apply(toMessage: message.globalMessageNumber, fields: message.fields)
                if enriched.messageName == nil {
                    Self.logger.debug("Unknown message number \(message.globalMessageNumber) with \(message.fields.count) fields")
                }
            }
        }

        guard let session = sessionFields else {
            Self.logger.warning("No session message found in activity FIT file")
            return nil
        }

        return buildActivity(from: session, trackPoints: trackPoints)
    }

    // MARK: - Private helpers

    private func parseTrackPoint(from fields: [UInt8: FITFieldValue]) -> TrackPoint? {
        guard let timestamp = fields[Self.recordTimestamp].flatMap(FITTimestamp.date(from:)),
              let latSemi = fields[Self.recordLatitude]?.intValue,
              let lonSemi = fields[Self.recordLongitude]?.intValue else {
            return nil
        }

        let latitude = Double(latSemi) * Self.semicirclesToDegrees
        let longitude = Double(lonSemi) * Self.semicirclesToDegrees

        // Altitude: stored with scale 5, offset 500.
        let altitude: Double? = fields[Self.recordAltitude]?.doubleValue.map { ($0 / 5.0) - 500.0 }
        let heartRate = fields[Self.recordHeartRate]?.intValue
        let cadence = fields[Self.recordCadence]?.intValue
        let speed: Double? = fields[Self.recordSpeed]?.doubleValue.map { $0 / 1000.0 }
        let temperature: Double? = fields[Self.recordTemperature]?.doubleValue

        return TrackPoint(
            timestamp: timestamp,
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            heartRate: heartRate,
            cadence: cadence,
            speed: speed,
            temperature: temperature
        )
    }

    private func buildActivity(from session: [UInt8: FITFieldValue], trackPoints: [TrackPoint]) -> Activity {
        let startDate: Date
        if let ts = session[Self.fieldStartTime].flatMap(FITTimestamp.date(from:)) {
            startDate = ts
        } else if let ts = session[Self.fieldTimestamp].flatMap(FITTimestamp.date(from:)) {
            startDate = ts
        } else {
            startDate = Date()
        }

        // Total elapsed time is in ms (scale 1000 in the FIT SDK).
        let durationRaw = session[Self.fieldTotalElapsedTime]?.doubleValue ?? 0
        let duration: TimeInterval = durationRaw / 1000.0
        let endDate = startDate.addingTimeInterval(duration)

        // Distance is in cm (scale 100).
        let distanceRaw = session[Self.fieldTotalDistance]?.doubleValue ?? 0
        let distance = distanceRaw / 100.0

        let totalCalories = session[Self.fieldTotalCalories]?.doubleValue ?? 0
        let avgHR = session[Self.fieldAvgHeartRate]?.intValue
        let maxHR = session[Self.fieldMaxHeartRate]?.intValue
        let ascent = session[Self.fieldTotalAscent]?.doubleValue
        let descent = session[Self.fieldTotalDescent]?.doubleValue

        let sport = mapSport(from: session)

        return Activity(
            startDate: startDate,
            endDate: endDate,
            sport: sport,
            distance: distance,
            duration: duration,
            totalCalories: totalCalories,
            avgHeartRate: avgHR,
            maxHeartRate: maxHR,
            totalAscent: ascent,
            totalDescent: descent,
            trackPoints: trackPoints
        )
    }

    /// Maps FIT sport enum to CompassData `Sport`.
    ///
    /// FIT sport enum values (from the FIT SDK Profile):
    /// 0 = generic, 1 = running, 2 = cycling, 5 = swimming, 10 = training,
    /// 11 = walking, 17 = hiking, 20 = strength_training, etc.
    private func mapSport(from session: [UInt8: FITFieldValue]) -> Sport {
        // The sport field in a session message is field 5 with enum base type.
        guard let sportValue = session[Self.fieldSessionSport]?.intValue else {
            return .other
        }
        switch sportValue {
        case 1:  return .running
        case 2:  return .cycling
        case 5:  return .swimming
        case 11: return .walking
        case 17: return .hiking
        case 10, 20: return .strength
        case 13: return .cardio // fitness_equipment often maps to cardio
        default: return .other
        }
    }
}

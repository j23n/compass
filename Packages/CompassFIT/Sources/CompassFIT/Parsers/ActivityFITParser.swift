import Foundation
import os
import FitFileParser
import CompassData

/// Parses Garmin `/GARMIN/Activity/*.fit` files into `Activity` and `TrackPoint` models.
///
/// Uses `.fast` parsing — scale/offset are pre-applied so values are already in their
/// natural units (m, m/s, s, kcal, bpm, °C).
public struct ActivityFITParser: Sendable {

    private static let logger = Logger(subsystem: "com.compass.fit", category: "ActivityFITParser")

    public init() {}

    public func parse(data: Data) async throws -> Activity? {
        let fitFile = FitFile(data: data, parsingType: .fast)

        var sessionMessage: FitMessage?
        var trackPoints: [TrackPoint] = []

        for message in fitFile.messages {
            switch message.messageType {
            case .session:
                if sessionMessage == nil {
                    sessionMessage = message
                }

            case .record:
                if let tp = parseTrackPoint(from: message) {
                    trackPoints.append(tp)
                }

            case .lap:
                Self.logger.debug("Lap message found; not yet mapped")

            default:
                break
            }
        }

        guard let session = sessionMessage else {
            Self.logger.warning("No session message found in activity FIT file")
            return nil
        }

        return buildActivity(from: session, trackPoints: trackPoints)
    }

    // MARK: - Private helpers

    private func parseTrackPoint(from message: FitMessage) -> TrackPoint? {
        guard let timestamp = message.interpretedField(key: "timestamp")?.time else {
            return nil
        }

        // GPS is optional — indoor/treadmill activities have HR/cadence but no coordinates.
        let coord = message.interpretedField(key: "position")?.coordinate
        let latitude = coord?.latitude ?? 0.0
        let longitude = coord?.longitude ?? 0.0

        let altitude = doubleValue(message, key: "altitude")
        let heartRate = message.interpretedField(key: "heart_rate")?.value.map(Int.init)
        let cadence = message.interpretedField(key: "cadence")?.value.map(Int.init)
        let speed = doubleValue(message, key: "speed")
        let temperature = doubleValue(message, key: "temperature")

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

    private func buildActivity(from session: FitMessage, trackPoints: [TrackPoint]) -> Activity {
        let startDate = session.interpretedField(key: "start_time")?.time
                     ?? session.interpretedField(key: "timestamp")?.time
                     ?? Date()

        let duration = doubleValue(session, key: "total_elapsed_time") ?? 0
        let endDate = startDate.addingTimeInterval(duration)
        let distance = doubleValue(session, key: "total_distance") ?? 0
        let activeCalories = doubleValue(session, key: "total_calories") ?? 0
        let avgHR = session.interpretedField(key: "avg_heart_rate")?.value.map(Int.init)
        let maxHR = session.interpretedField(key: "max_heart_rate")?.value.map(Int.init)
        let ascent = doubleValue(session, key: "total_ascent")
        let descent = doubleValue(session, key: "total_descent")

        return Activity(
            startDate: startDate,
            endDate: endDate,
            sport: mapSport(from: session),
            distance: distance,
            duration: duration,
            activeCalories: activeCalories,
            avgHeartRate: avgHR,
            maxHeartRate: maxHR,
            totalAscent: ascent,
            totalDescent: descent,
            trackPoints: trackPoints
        )
    }

    /// Maps FIT sport / sub_sport string enums to CompassData `Sport`.
    private func mapSport(from session: FitMessage) -> Sport {
        let subSport = session.interpretedField(key: "sub_sport")?.name
        let sport    = session.interpretedField(key: "sport")?.name

        switch subSport {
        case "yoga", "pilates":   return .yoga
        case "strength_training": return .strength
        case "mountaineering":    return .climbing
        default: break
        }

        if sport == "cycling", subSport == "mountain" || subSport == "downhill" {
            return .mtb
        }

        switch sport {
        case "running":                 return .running
        case "cycling":                 return .cycling
        case "swimming":                return .swimming
        case "walking":                 return .walking
        case "hiking":                  return .hiking
        case "rowing":                  return .rowing
        case "kayaking":                return .kayaking
        case "snowboarding":            return .snowboarding
        case "stand_up_paddleboarding": return .sup
        case "boating":                 return .boating
        case "fitness_equipment":       return .cardio
        default:                        return .other
        }
    }

    private func doubleValue(_ message: FitMessage, key: String) -> Double? {
        let fv = message.interpretedField(key: key)
        return fv?.value ?? fv?.valueUnit?.value
    }
}

import Foundation
import os
import FitFileParser
import CompassData

/// Parses a `.fit` course file (file_id type = course, 6) into a
/// `ParsedGPXCourse`. Mirrors what `CourseFITEncoder` writes, but is also
/// tolerant of richer Garmin-Connect-produced files: extra messages are
/// ignored, missing optional fields fall back to nil.
///
/// Only handles **course** files, not activity recordings. Activities have a
/// `session` message; courses have a `course` message. We refuse anything
/// without a course message so users can't accidentally import a workout as
/// a route.
public struct FITCourseParser: Sendable {

    public enum FITCourseParserError: LocalizedError {
        case notACourseFile
        case noRecords

        public var errorDescription: String? {
            switch self {
            case .notACourseFile:
                return "This FIT file isn't a course (no `course` message found)."
            case .noRecords:
                return "FIT course contains no track points."
            }
        }
    }

    private static let logger = Logger(subsystem: "com.compass.fit", category: "FITCourseParser")

    /// FIT global message number for `course_point` — not exposed as a
    /// `static let` on `FitMessageType`, so we use the literal.
    private static let coursePointMesgNum: FitMessageType = 32

    public init() {}

    public static func parse(data: Data) throws -> ParsedGPXCourse {
        let fitFile = FitFile(data: data, parsingType: .fast)

        var courseName: String?
        var totalDistance: Double = 0
        var totalAscent: Double?
        var totalDescent: Double?
        var hasCourseMessage = false

        var records: [GPXWaypoint] = []
        var pois: [GPXPointOfInterest] = []

        var firstRecordTime: Date?

        for message in fitFile.messages {
            switch message.messageType {
            case .course:
                hasCourseMessage = true
                if let name = message.interpretedField(key: "name")?.name {
                    courseName = name
                }

            case .lap:
                if let distance = doubleValue(message, "total_distance"), distance > 0 {
                    totalDistance = distance
                }
                if let ascent = doubleValue(message, "total_ascent"), ascent.isFinite {
                    totalAscent = ascent
                }
                if let descent = doubleValue(message, "total_descent"), descent.isFinite {
                    totalDescent = descent
                }

            case .record:
                guard let coord = message.interpretedField(key: "position")?.coordinate else {
                    continue
                }
                let altitude = doubleValue(message, "enhanced_altitude")
                            ?? doubleValue(message, "altitude")
                let distance = doubleValue(message, "distance") ?? 0
                let timestamp = message.interpretedField(key: "timestamp")?.time
                if firstRecordTime == nil { firstRecordTime = timestamp }

                records.append(GPXWaypoint(
                    latitude: coord.latitude,
                    longitude: coord.longitude,
                    altitude: altitude,
                    name: nil,
                    distanceFromStart: distance,
                    timestamp: timestamp
                ))

            case Self.coursePointMesgNum:
                guard let coord = message.interpretedField(key: "position")?.coordinate else {
                    continue
                }
                let name = message.interpretedField(key: "name")?.name ?? ""
                let distance = doubleValue(message, "distance") ?? 0
                let typeName = message.interpretedField(key: "type")?.name
                // Course-point type comes back as a string ("summit", "left", …);
                // re-resolve via our shared catalogue. Falls back to .generic.
                let resolved = CoursePointType.resolve(gpxType: typeName, gpxSym: nil)
                pois.append(GPXPointOfInterest(
                    latitude: coord.latitude,
                    longitude: coord.longitude,
                    name: name.isEmpty ? resolved.displayName : name,
                    symbol: typeName,
                    distanceFromStart: distance,
                    coursePointType: resolved.fitCode
                ))

            default:
                break
            }
        }

        guard hasCourseMessage else { throw FITCourseParserError.notACourseFile }
        guard !records.isEmpty else { throw FITCourseParserError.noRecords }

        // If the lap didn't carry total_distance, derive it from the last record.
        if totalDistance == 0 {
            totalDistance = records.last?.distanceFromStart ?? 0
        }
        // If lap ascent/descent were missing, fall back to summing altitude deltas.
        if totalAscent == nil || totalDescent == nil {
            var asc: Double = 0, desc: Double = 0
            for i in 1..<records.count {
                guard let prev = records[i - 1].altitude,
                      let curr = records[i].altitude else { continue }
                let d = curr - prev
                if d > 0 { asc += d } else { desc -= d }
            }
            if totalAscent == nil, asc > 0 { totalAscent = asc }
            if totalDescent == nil, desc > 0 { totalDescent = desc }
        }

        return ParsedGPXCourse(
            name: courseName ?? "",
            waypoints: records,
            pointsOfInterest: pois,
            totalDistance: totalDistance,
            totalAscent: totalAscent,
            totalDescent: totalDescent
        )
    }

    // MARK: - Private helpers

    private static func doubleValue(_ message: FitMessage, _ key: String) -> Double? {
        message.interpretedField(key: key)?.value
    }
}

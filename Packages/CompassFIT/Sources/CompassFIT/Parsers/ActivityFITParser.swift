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
        var timerEvents: [(timestamp: Date, isStart: Bool)] = []

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

            case Self.eventMesgNum:
                if let parsed = parseTimerEvent(from: message) {
                    timerEvents.append(parsed)
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

        let pauses = derivePauses(events: timerEvents, trackPoints: trackPoints)
        return buildActivity(from: session, trackPoints: trackPoints, pauses: pauses)
    }

    // FIT global mesg_num for `event` (21). FitMessageType isn't an enum,
    // it's an Int typealias, so we match against the raw value.
    private static let eventMesgNum: FitMessageType = 21

    /// Pull a (timestamp, isStart) pair out of a FIT `event` message if it's
    /// a timer event we care about. Returns nil for non-timer events.
    ///
    /// FIT semantics: event=0 (timer), event_type=0 (start) bracket recording;
    /// stop/stop_all/stop_disable/stop_disable_all all mean "pause". A
    /// resume is a subsequent timer-start.
    private func parseTimerEvent(from message: FitMessage) -> (timestamp: Date, isStart: Bool)? {
        guard let ts = message.interpretedField(key: "timestamp")?.time else { return nil }
        guard let event = message.interpretedField(key: "event")?.name, event == "timer" else { return nil }
        guard let evType = message.interpretedField(key: "event_type")?.name else { return nil }
        switch evType {
        case "start":
            return (ts, true)
        case "stop", "stop_all", "stop_disable", "stop_disable_all":
            return (ts, false)
        default:
            return nil
        }
    }

    /// Speed (m/s) below which a sample counts as "stationary" for inferred
    /// pause detection. 0.3 m/s ≈ 1.1 km/h — slower than the slowest walk,
    /// well above typical GPS noise on a stationary device.
    private static let stationarySpeedThreshold: Double = 0.3

    /// Minimum continuous duration (s) of stationary samples to register as
    /// an inferred pause. Same threshold as before so brief stops (traffic
    /// lights, photo breaks) aren't surfaced.
    private static let stationaryPauseDuration: TimeInterval = 60

    /// Combine FIT timer events with stationary-speed inference. FIT events
    /// are authoritative when present; the inferred pauses are added only
    /// where they don't overlap an existing FIT-explicit pause.
    ///
    /// "Stationary" requires the watch to have recorded a speed reading
    /// below the threshold — samples *without* a speed field (yoga,
    /// strength training, any indoor sport without a speed sensor) are
    /// skipped entirely, so non-GPS workouts can never produce false
    /// positives. The previous wall-clock gap heuristic was replaced
    /// because it missed the common case of sitting on a bench with the
    /// watch still recording 1 Hz HR and zero-speed samples.
    private func derivePauses(
        events: [(timestamp: Date, isStart: Bool)],
        trackPoints: [TrackPoint]
    ) -> [(start: Date, end: Date)] {
        var pauses: [(start: Date, end: Date)] = []

        // Walk sorted timer events; each stop opens a pause, the next start
        // closes it. Discard unclosed/duplicate pairs defensively.
        let sortedEvents = events.sorted { $0.timestamp < $1.timestamp }
        var openStop: Date?
        for ev in sortedEvents {
            if ev.isStart {
                if let stopAt = openStop, ev.timestamp > stopAt {
                    pauses.append((start: stopAt, end: ev.timestamp))
                }
                openStop = nil
            } else {
                // Only the FIRST stop in a sequence matters — repeated stops
                // before a start don't open new pauses.
                if openStop == nil { openStop = ev.timestamp }
            }
        }

        // Stationary-speed inference. Walk the trackpoint stream and
        // track runs of consecutive low-speed samples; a run that lasts
        // ≥ stationaryPauseDuration becomes an inferred pause. Samples
        // without a speed value are passed over without closing the run
        // (rare in practice — GPS streams are consistent) but also
        // without opening one, so indoor workouts produce nothing.
        let sortedPoints = trackPoints.sorted { $0.timestamp < $1.timestamp }
        var runStart: Date?
        var runEnd: Date?

        func closeRunIfQualifies() {
            guard let s = runStart, let e = runEnd,
                  e.timeIntervalSince(s) >= Self.stationaryPauseDuration else {
                runStart = nil; runEnd = nil
                return
            }
            // Skip if covered by a FIT pause (5 s clock-skew tolerance).
            let overlapsFit = pauses.contains { fit in
                fit.start <= s.addingTimeInterval(5)
                    && fit.end >= e.addingTimeInterval(-5)
            }
            if !overlapsFit {
                pauses.append((start: s, end: e))
            }
            runStart = nil; runEnd = nil
        }

        for tp in sortedPoints {
            guard let speed = tp.speed else { continue }
            if speed < Self.stationarySpeedThreshold {
                if runStart == nil { runStart = tp.timestamp }
                runEnd = tp.timestamp
            } else {
                closeRunIfQualifies()
            }
        }
        // Activity may end while still stationary (watch stopped without
        // moving again) — close out any open run.
        closeRunIfQualifies()

        return pauses.sorted { $0.start < $1.start }
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

        let altitude = doubleValue(message, key: "enhanced_altitude")
                    ?? doubleValue(message, key: "altitude")
        let heartRate = doubleValue(message, key: "heart_rate").map(Int.init)
        let cadence = doubleValue(message, key: "cadence").map(Int.init)
        let speed = doubleValue(message, key: "enhanced_speed")
                 ?? doubleValue(message, key: "speed")
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

    /// RDP epsilon for the persisted activity-list thumbnail polyline.
    /// 8 m keeps shape recognisable for a 60×60 thumbnail while typically
    /// dropping a 5000-point ride to ~150 vertices.
    private static let thumbnailSimplifyEpsilon: Double = 8

    private func buildActivity(
        from session: FitMessage,
        trackPoints: [TrackPoint],
        pauses: [(start: Date, end: Date)]
    ) -> Activity {
        let startDate = session.interpretedField(key: "start_time")?.time
                     ?? session.interpretedField(key: "timestamp")?.time
                     ?? Date()

        let duration = doubleValue(session, key: "total_elapsed_time") ?? 0
        let endDate = startDate.addingTimeInterval(duration)
        let distance = doubleValue(session, key: "total_distance") ?? 0
        let activeCalories = doubleValue(session, key: "total_calories") ?? 0
        let avgHR = doubleValue(session, key: "avg_heart_rate").map(Int.init)
        let maxHR = doubleValue(session, key: "max_heart_rate").map(Int.init)
        let ascent = doubleValue(session, key: "total_ascent")
        let descent = doubleValue(session, key: "total_descent")

        // Pre-compute a simplified polyline for the activities-list
        // thumbnail. Filtering out (0, 0) sentinel points first avoids RDP
        // pulling the centre of the Atlantic into the route when indoor
        // segments are mixed with outdoor ones.
        let gpsCoords = trackPoints
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap { tp -> (lat: Double, lon: Double)? in
                guard tp.latitude != 0 || tp.longitude != 0 else { return nil }
                return (tp.latitude, tp.longitude)
            }
        let keepIdx = PathSimplification.simplify(
            points: gpsCoords,
            epsilon: Self.thumbnailSimplifyEpsilon
        )
        let simplifiedLat = keepIdx.map { gpsCoords[$0].lat }
        let simplifiedLon = keepIdx.map { gpsCoords[$0].lon }

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
            pauseStarts: pauses.map(\.start),
            pauseEnds: pauses.map(\.end),
            simplifiedLat: simplifiedLat,
            simplifiedLon: simplifiedLon,
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

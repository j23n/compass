import Foundation
import CompassData

public enum GPXCourseParserError: LocalizedError {
    case invalidGPXFormat(String)
    case noTrackPoints
    case parsingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidGPXFormat(let msg):
            return "Invalid GPX format: \(msg)"
        case .noTrackPoints:
            return "GPX file contains no track points"
        case .parsingFailed(let msg):
            return "GPX parsing failed: \(msg)"
        }
    }
}

/// Simple waypoint structure for parsed GPX data.
public struct GPXWaypoint: Sendable {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double?
    public let name: String?
    public let distanceFromStart: Double
    /// UTC timestamp from the GPX `<time>` element, if present.
    public let timestamp: Date?

    public init(latitude: Double, longitude: Double, altitude: Double? = nil, name: String? = nil, distanceFromStart: Double, timestamp: Date? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.name = name
        self.distanceFromStart = distanceFromStart
        self.timestamp = timestamp
    }
}

/// A point of interest from a GPX `<wpt>` element. POIs are markers along
/// the route (not part of the route itself) — e.g., water fountains, summits,
/// turn cues. They become FIT `course_point` messages.
public struct GPXPointOfInterest: Sendable {
    public let latitude: Double
    public let longitude: Double
    public let name: String
    /// Free-form symbol/category from the GPX `<sym>` element (e.g., "Drinking Water", "Flag, Blue", "Summit").
    public let symbol: String?
    /// Cumulative distance (m) from course start to the closest track point — used for FIT `course_point.distance`.
    public let distanceFromStart: Double
    /// FIT `course_point` type enum value (0=generic, 1=summit, 3=water, 4=food, 5=danger, …).
    public let coursePointType: UInt8

    public init(latitude: Double, longitude: Double, name: String, symbol: String?, distanceFromStart: Double, coursePointType: UInt8) {
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
        self.symbol = symbol
        self.distanceFromStart = distanceFromStart
        self.coursePointType = coursePointType
    }
}

/// Parsed GPX course data structure.
public struct ParsedGPXCourse: Sendable {
    public let name: String
    public let waypoints: [GPXWaypoint]
    public let pointsOfInterest: [GPXPointOfInterest]
    public let totalDistance: Double
    /// Total elevation gain in metres (nil if no altitude data in the GPX).
    public let totalAscent: Double?
    /// Total elevation loss in metres (nil if no altitude data in the GPX).
    public let totalDescent: Double?

    public init(name: String, waypoints: [GPXWaypoint], pointsOfInterest: [GPXPointOfInterest] = [], totalDistance: Double, totalAscent: Double? = nil, totalDescent: Double? = nil) {
        self.name = name
        self.waypoints = waypoints
        self.pointsOfInterest = pointsOfInterest
        self.totalDistance = totalDistance
        self.totalAscent = totalAscent
        self.totalDescent = totalDescent
    }
}

public struct GPXCourseParser: Sendable {

    /// Parses a GPX file into a ParsedGPXCourse structure.
    public static func parse(data: Data) throws -> ParsedGPXCourse {
        let delegate = GPXParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate

        if !parser.parse() {
            if let error = parser.parserError {
                throw GPXCourseParserError.parsingFailed(error.localizedDescription)
            }
            throw GPXCourseParserError.parsingFailed("Unknown XML parsing error")
        }

        guard !delegate.trackPoints.isEmpty else {
            throw GPXCourseParserError.noTrackPoints
        }

        // Simplify track points with Ramer-Douglas-Peucker (10 m epsilon)
        let rawCoords = delegate.trackPoints.map { (lat: $0.latitude, lon: $0.longitude) }
        let keptIndices = PathSimplification.simplify(points: rawCoords, epsilon: 3.0)
        let simplifiedPoints = keptIndices.map { delegate.trackPoints[$0] }

        // Compute cumulative distances using Haversine on simplified points
        var waypoints: [GPXWaypoint] = []
        var cumulativeDistance: Double = 0

        for (index, point) in simplifiedPoints.enumerated() {
            if index > 0 {
                let prevPoint = simplifiedPoints[index - 1]
                cumulativeDistance += haversineDistance(
                    lat1: prevPoint.latitude, lon1: prevPoint.longitude,
                    lat2: point.latitude, lon2: point.longitude
                )
            }

            waypoints.append(GPXWaypoint(
                latitude: point.latitude,
                longitude: point.longitude,
                altitude: point.altitude,
                name: nil,
                distanceFromStart: cumulativeDistance,
                timestamp: point.timestamp
            ))
        }

        // Compute elevation gain/loss across simplified waypoints
        var totalAscent: Double = 0
        var totalDescent: Double = 0
        for i in 1..<waypoints.count {
            guard let prev = waypoints[i - 1].altitude, let curr = waypoints[i].altitude else { continue }
            let diff = curr - prev
            if diff > 0 { totalAscent += diff } else { totalDescent -= diff }
        }

        // Build POIs at their actual lat/lon, with distance taken from the
        // closest track point along the route. Prefer GPX <type> (Garmin /
        // Strava / RWGPS) over <sym> (Komoot) when both are present.
        var pois: [GPXPointOfInterest] = delegate.namedWaypoints.map { wpt in
            let closestDistance = findClosestWaypoint(
                to: (wpt.latitude, wpt.longitude),
                in: waypoints
            ).map { waypoints[$0].distanceFromStart } ?? 0
            let resolved = CoursePointType.resolve(gpxType: wpt.type, gpxSym: wpt.symbol)
            return GPXPointOfInterest(
                latitude: wpt.latitude,
                longitude: wpt.longitude,
                name: wpt.name,
                symbol: wpt.symbol ?? wpt.type,
                distanceFromStart: closestDistance,
                coursePointType: resolved.fitCode
            )
        }

        // Synthesise turn cues from sharp bearing changes in the simplified
        // polyline. These become extra POIs with type left/right/slight/sharp/
        // u_turn so the watch fires turn alerts even when the GPX source
        // (Komoot, plain track exports) doesn't include navigation cues.
        let synthesisedTurns = detectTurns(in: waypoints)
        pois.append(contentsOf: synthesisedTurns)

        // Return the raw trk name (possibly empty); callers should fall back to
        // the source filename if they need a non-empty name.
        return ParsedGPXCourse(
            name: delegate.trackName,
            waypoints: waypoints,
            pointsOfInterest: pois,
            totalDistance: cumulativeDistance,
            totalAscent: totalAscent > 0 ? totalAscent : nil,
            totalDescent: totalDescent > 0 ? totalDescent : nil
        )
    }

    // MARK: - Turn detection

    /// Bearing-change thresholds (degrees) for synthesising turn course_points
    /// from a track polyline. Tiered so a 50° kink becomes a `slightLeft`
    /// rather than an aggressive `left`.
    private static let turnSlightThreshold: Double = 45
    private static let turnNormalThreshold: Double = 70
    private static let turnSharpThreshold:  Double = 120
    private static let turnUTurnThreshold:  Double = 160

    /// Minimum spacing between successive synthetic turn cues (m). Prevents
    /// emitting two adjacent turns on a tight switchback that simplifies to
    /// two close vertices.
    private static let minTurnSpacing: Double = 20

    /// Window used to compute the bearing on either side of a vertex (m).
    /// We average bearings over the segment(s) up to this length so a
    /// single noisy GPS point doesn't masquerade as a turn.
    private static let bearingWindow: Double = 25

    /// Detect sharp bearing changes in the simplified track and emit
    /// `GPXPointOfInterest` markers for each. Names are auto-generated
    /// ("Left", "Sharp right", "U-turn"); the user can rename them later
    /// in the POI editor.
    private static func detectTurns(in waypoints: [GPXWaypoint]) -> [GPXPointOfInterest] {
        guard waypoints.count >= 3 else { return [] }

        var turns: [GPXPointOfInterest] = []
        var lastEmittedDistance: Double = -Double.infinity

        for i in 1..<(waypoints.count - 1) {
            let pivot = waypoints[i]

            // Skip if we just emitted a turn very close by.
            if pivot.distanceFromStart - lastEmittedDistance < minTurnSpacing {
                continue
            }

            // Bearing in: average over points up to bearingWindow metres
            // before the pivot. Bearing out: same, after.
            guard let bearingIn  = averageBearing(approaching: i, in: waypoints),
                  let bearingOut = averageBearing(departing:   i, in: waypoints) else {
                continue
            }

            let delta = signedBearingDelta(from: bearingIn, to: bearingOut)
            let absDelta = abs(delta)
            guard absDelta >= turnSlightThreshold else { continue }

            let isLeft = delta < 0
            let type: CoursePointType
            if absDelta >= turnUTurnThreshold {
                type = .uTurn
            } else if absDelta >= turnSharpThreshold {
                type = isLeft ? .sharpLeft : .sharpRight
            } else if absDelta >= turnNormalThreshold {
                type = isLeft ? .left : .right
            } else {
                type = isLeft ? .slightLeft : .slightRight
            }

            turns.append(GPXPointOfInterest(
                latitude: pivot.latitude,
                longitude: pivot.longitude,
                name: type.displayName,
                symbol: nil,
                distanceFromStart: pivot.distanceFromStart,
                coursePointType: type.fitCode
            ))
            lastEmittedDistance = pivot.distanceFromStart
        }

        return turns
    }

    /// Average bearing over the segments immediately *before* index `i`,
    /// walking backwards until we've covered `bearingWindow` metres (or run
    /// out of points). Bearings are averaged in vector form to handle the
    /// 360°/0° wraparound correctly.
    private static func averageBearing(approaching i: Int, in waypoints: [GPXWaypoint]) -> Double? {
        guard i > 0 else { return nil }
        var sumX: Double = 0, sumY: Double = 0
        var travelled: Double = 0
        var j = i
        while j > 0 && travelled < bearingWindow {
            let a = waypoints[j - 1], b = waypoints[j]
            let seg = haversineDistance(lat1: a.latitude, lon1: a.longitude,
                                        lat2: b.latitude, lon2: b.longitude)
            if seg > 0 {
                let bearing = bearingDegrees(from: a, to: b)
                let rad = bearing * .pi / 180
                sumX += cos(rad) * seg
                sumY += sin(rad) * seg
                travelled += seg
            }
            j -= 1
        }
        guard sumX != 0 || sumY != 0 else { return nil }
        let avg = atan2(sumY, sumX) * 180 / .pi
        return (avg + 360).truncatingRemainder(dividingBy: 360)
    }

    private static func averageBearing(departing i: Int, in waypoints: [GPXWaypoint]) -> Double? {
        guard i < waypoints.count - 1 else { return nil }
        var sumX: Double = 0, sumY: Double = 0
        var travelled: Double = 0
        var j = i
        while j < waypoints.count - 1 && travelled < bearingWindow {
            let a = waypoints[j], b = waypoints[j + 1]
            let seg = haversineDistance(lat1: a.latitude, lon1: a.longitude,
                                        lat2: b.latitude, lon2: b.longitude)
            if seg > 0 {
                let bearing = bearingDegrees(from: a, to: b)
                let rad = bearing * .pi / 180
                sumX += cos(rad) * seg
                sumY += sin(rad) * seg
                travelled += seg
            }
            j += 1
        }
        guard sumX != 0 || sumY != 0 else { return nil }
        let avg = atan2(sumY, sumX) * 180 / .pi
        return (avg + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Initial bearing from a → b, in degrees [0, 360).
    private static func bearingDegrees(from a: GPXWaypoint, to b: GPXWaypoint) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Signed angle from bearing `a` to bearing `b`, in range (-180, 180].
    /// Negative = left turn, positive = right turn.
    private static func signedBearingDelta(from a: Double, to b: Double) -> Double {
        var d = b - a
        while d <= -180 { d += 360 }
        while d > 180   { d -= 360 }
        return d
    }

    // MARK: - Helpers

    /// Find the index of the closest waypoint to a given coordinate
    private static func findClosestWaypoint(
        to coordinate: (lat: Double, lon: Double),
        in waypoints: [GPXWaypoint]
    ) -> Int? {
        var closestIndex: Int? = nil
        var minDistance = Double.infinity

        for (index, waypoint) in waypoints.enumerated() {
            let distance = haversineDistance(
                lat1: waypoint.latitude, lon1: waypoint.longitude,
                lat2: coordinate.lat, lon2: coordinate.lon
            )
            if distance < minDistance {
                minDistance = distance
                closestIndex = index
            }
        }

        return closestIndex
    }
}

// MARK: - XMLParser Delegate

private class GPXParserDelegate: NSObject, XMLParserDelegate {
    var trackPoints: [(latitude: Double, longitude: Double, altitude: Double?, timestamp: Date?)] = []
    var namedWaypoints: [(latitude: Double, longitude: Double, name: String, symbol: String?, type: String?)] = []
    var trackName: String = ""

    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private var currentElement: String = ""
    private var currentLat: Double? = nil
    private var currentLon: Double? = nil
    private var currentAlt: Double? = nil
    private var currentTimestamp: Date? = nil
    private var currentName: String = ""
    private var currentSymbol: String? = nil
    private var currentType: String? = nil
    /// True while we're inside a `<wpt>` element; the `<type>` child means
    /// "POI category" there. Outside a `<wpt>` (e.g., on `<rtept>` or stray
    /// `<type>` tags in `<author><link>`), we ignore it.
    private var insideWaypoint: Bool = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String : String] = [:]
    ) {
        currentElement = elementName

        switch elementName {
        case "trkpt":
            // Don't touch currentName here — the surrounding <trk><name>...</name>
            // is captured into currentName before the first <trkpt> opens, and
            // <trkpt> doesn't have its own <name> child to overwrite.
            if let lat = attributeDict["lat"], let latVal = Double(lat) {
                currentLat = latVal
            }
            if let lon = attributeDict["lon"], let lonVal = Double(lon) {
                currentLon = lonVal
            }
            currentTimestamp = nil

        case "wpt":
            // Reset name/sym so a <wpt>'s <name> doesn't append to whatever
            // was last in currentName (e.g., the metadata <name>).
            if let lat = attributeDict["lat"], let latVal = Double(lat) {
                currentLat = latVal
            }
            if let lon = attributeDict["lon"], let lonVal = Double(lon) {
                currentLon = lonVal
            }
            currentName = ""
            currentSymbol = nil
            currentType = nil
            currentTimestamp = nil
            insideWaypoint = true

        case "trk":
            currentName = ""

        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "trkpt":
            if let lat = currentLat, let lon = currentLon {
                trackPoints.append((latitude: lat, longitude: lon, altitude: currentAlt, timestamp: currentTimestamp))
                currentLat = nil
                currentLon = nil
                currentAlt = nil
                currentTimestamp = nil
            }

        case "wpt":
            if let lat = currentLat, let lon = currentLon, !currentName.isEmpty {
                namedWaypoints.append((latitude: lat, longitude: lon, name: currentName, symbol: currentSymbol, type: currentType))
                currentLat = nil
                currentLon = nil
                currentName = ""
                currentSymbol = nil
                currentType = nil
            }
            insideWaypoint = false

        case "trk":
            if trackName.isEmpty && !currentName.isEmpty {
                trackName = currentName.trimmingCharacters(in: .whitespaces)
            }

        default:
            break
        }

        currentElement = ""
    }

    func parser(
        _ parser: XMLParser,
        foundCharacters string: String
    ) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        switch currentElement {
        case "ele":
            currentAlt = Double(trimmed)
        case "time":
            // Try with fractional seconds first, then without
            currentTimestamp = GPXParserDelegate.iso8601.date(from: trimmed)
                ?? ISO8601DateFormatter().date(from: trimmed)
        case "name":
            currentName.append(trimmed)
        case "sym":
            currentSymbol = (currentSymbol ?? "") + trimmed
        case "type":
            // Only collect <type> inside a <wpt>; outside a waypoint the tag
            // typically describes a link MIME type (text/html) and isn't useful.
            if insideWaypoint {
                currentType = (currentType ?? "") + trimmed
            }
        default:
            break
        }
    }
}

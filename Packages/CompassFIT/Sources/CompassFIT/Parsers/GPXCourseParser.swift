import Foundation

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
        // closest track point along the route.
        let pois: [GPXPointOfInterest] = delegate.namedWaypoints.map { wpt in
            let closestDistance = findClosestWaypoint(
                to: (wpt.latitude, wpt.longitude),
                in: waypoints
            ).map { waypoints[$0].distanceFromStart } ?? 0
            return GPXPointOfInterest(
                latitude: wpt.latitude,
                longitude: wpt.longitude,
                name: wpt.name,
                symbol: wpt.symbol,
                distanceFromStart: closestDistance,
                coursePointType: coursePointType(forSymbol: wpt.symbol)
            )
        }

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

    /// Map a GPX `<sym>` value to a FIT `course_point` type enum.
    /// Common Garmin/OsmAnd symbol names → FIT course_point. Unknown → generic (0).
    private static func coursePointType(forSymbol sym: String?) -> UInt8 {
        guard let s = sym?.lowercased() else { return 0 }
        if s.contains("water") || s.contains("fountain") || s.contains("drinking") { return 3 }
        if s.contains("summit") || s.contains("peak") || s.contains("mountain") { return 1 }
        if s.contains("valley") { return 2 }
        if s.contains("food") || s.contains("restaurant") || s.contains("cafe") { return 4 }
        if s.contains("danger") || s.contains("warning") { return 5 }
        if s.contains("first aid") || s.contains("medical") || s.contains("hospital") { return 9 }
        if s.contains("left") { return 6 }
        if s.contains("right") { return 7 }
        if s.contains("straight") { return 8 }
        return 0  // generic
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
    var namedWaypoints: [(latitude: Double, longitude: Double, name: String, symbol: String?)] = []
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
            currentTimestamp = nil

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
                namedWaypoints.append((latitude: lat, longitude: lon, name: currentName, symbol: currentSymbol))
                currentLat = nil
                currentLon = nil
                currentName = ""
                currentSymbol = nil
            }

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
        default:
            break
        }
    }
}

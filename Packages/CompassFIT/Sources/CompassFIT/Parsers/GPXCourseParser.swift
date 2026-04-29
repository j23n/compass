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

    public init(latitude: Double, longitude: Double, altitude: Double? = nil, name: String? = nil, distanceFromStart: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.name = name
        self.distanceFromStart = distanceFromStart
    }
}

/// Parsed GPX course data structure.
public struct ParsedGPXCourse: Sendable {
    public let name: String
    public let waypoints: [GPXWaypoint]
    public let totalDistance: Double

    public init(name: String, waypoints: [GPXWaypoint], totalDistance: Double) {
        self.name = name
        self.waypoints = waypoints
        self.totalDistance = totalDistance
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
                name: nil,  // Populated below from named waypoints
                distanceFromStart: cumulativeDistance
            ))
        }

        // Merge named waypoints by snapping to the closest track point
        for namedWaypoint in delegate.namedWaypoints {
            if let closestIndex = findClosestWaypoint(
                to: (namedWaypoint.latitude, namedWaypoint.longitude),
                in: waypoints
            ) {
                waypoints[closestIndex] = GPXWaypoint(
                    latitude: waypoints[closestIndex].latitude,
                    longitude: waypoints[closestIndex].longitude,
                    altitude: waypoints[closestIndex].altitude,
                    name: namedWaypoint.name,
                    distanceFromStart: waypoints[closestIndex].distanceFromStart
                )
            }
        }

        let courseName = delegate.trackName.isEmpty ? "Imported Course" : delegate.trackName

        return ParsedGPXCourse(
            name: courseName,
            waypoints: waypoints,
            totalDistance: cumulativeDistance
        )
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
    var trackPoints: [(latitude: Double, longitude: Double, altitude: Double?)] = []
    var namedWaypoints: [(latitude: Double, longitude: Double, name: String)] = []
    var trackName: String = ""

    private var currentElement: String = ""
    private var currentLat: Double? = nil
    private var currentLon: Double? = nil
    private var currentAlt: Double? = nil
    private var currentName: String = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String : String] = [:]
    ) {
        currentElement = elementName

        switch elementName {
        case "trkpt", "wpt":
            if let lat = attributeDict["lat"], let latVal = Double(lat) {
                currentLat = latVal
            }
            if let lon = attributeDict["lon"], let lonVal = Double(lon) {
                currentLon = lonVal
            }

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
                trackPoints.append((latitude: lat, longitude: lon, altitude: currentAlt))
                currentLat = nil
                currentLon = nil
                currentAlt = nil
            }

        case "wpt":
            if let lat = currentLat, let lon = currentLon, !currentName.isEmpty {
                namedWaypoints.append((latitude: lat, longitude: lon, name: currentName))
                currentLat = nil
                currentLon = nil
                currentName = ""
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
        case "name":
            currentName.append(trimmed)
        default:
            break
        }
    }
}

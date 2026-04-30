import Foundation
import SwiftData

@Model
public final class Course {
    #Unique<Course>([\.id])

    public var id: UUID
    public var name: String
    public var importDate: Date
    public var sport: Sport
    public var totalDistance: Double  // meters
    public var totalAscent: Double?   // meters
    public var totalDescent: Double?  // meters

    @Relationship(deleteRule: .cascade, inverse: \CourseWaypoint.course)
    public var waypoints: [CourseWaypoint]

    @Relationship(deleteRule: .cascade, inverse: \CoursePOI.course)
    public var pointsOfInterest: [CoursePOI] = []

    public var fitFileURL: URL?

    /// `true` after a successful upload to the watch; cleared if the watch confirms the file is gone.
    public var uploadedToWatch: Bool = false

    /// When the course was last uploaded.
    public var lastUploadDate: Date?

    /// Byte size of the FIT file we uploaded. Used to match the file in the watch's directory
    /// listing — more stable than fileIndex, which the watch reassigns when it renames/moves files.
    public var watchFITSize: Int?

    // MARK: - Computed

    /// Estimated moving time based on sport, distance, and elevation gain.
    ///
    /// Heuristics (Naismith-style):
    ///   Walk / hike : 5 km/h flat + 1 h per 600 m ascent
    ///   Running     : 10 km/h flat + 1 h per 300 m ascent
    ///   Cycling     : 17 km/h flat + 1 h per 500 m ascent
    ///   Other       : 8 km/h, no altitude factor
    public var estimatedDuration: TimeInterval {
        let km = totalDistance / 1_000
        let m  = (totalAscent ?? 0) + (totalDescent ?? 0)
        let hours: Double
        switch sport {
        case .walking, .hiking:
            hours = km / 5.0 + m / 600.0
        case .running:
            hours = km / 10.0 + m / 300.0
        case .cycling:
            hours = km / 17.0 + m / 500.0
        default:
            hours = km / 8.0
        }
        return hours * 3_600
    }

    public init(
        id: UUID = UUID(),
        name: String,
        importDate: Date,
        sport: Sport = .running,
        totalDistance: Double,
        totalAscent: Double? = nil,
        totalDescent: Double? = nil,
        waypoints: [CourseWaypoint] = [],
        fitFileURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.importDate = importDate
        self.sport = sport
        self.totalDistance = totalDistance
        self.totalAscent = totalAscent
        self.totalDescent = totalDescent
        self.waypoints = waypoints
        self.fitFileURL = fitFileURL
    }
}

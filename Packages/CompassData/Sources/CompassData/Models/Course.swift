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

    @Relationship(deleteRule: .cascade, inverse: \CourseWaypoint.course)
    public var waypoints: [CourseWaypoint]

    public var fitFileURL: URL?

    public init(
        id: UUID = UUID(),
        name: String,
        importDate: Date,
        sport: Sport = .running,
        totalDistance: Double,
        totalAscent: Double? = nil,
        waypoints: [CourseWaypoint] = [],
        fitFileURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.importDate = importDate
        self.sport = sport
        self.totalDistance = totalDistance
        self.totalAscent = totalAscent
        self.waypoints = waypoints
        self.fitFileURL = fitFileURL
    }
}

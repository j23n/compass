import Foundation
import SwiftData

@Model
public final class CourseWaypoint {
    public var order: Int
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?     // meters
    public var name: String?         // for turn-by-turn prompts
    public var distanceFromStart: Double  // meters (cumulative Haversine)
    /// UTC timestamp from the original GPX `<time>` element, if any.
    public var timestamp: Date?

    public var course: Course?

    public init(
        order: Int,
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil,
        name: String? = nil,
        distanceFromStart: Double,
        timestamp: Date? = nil,
        course: Course? = nil
    ) {
        self.order = order
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.name = name
        self.distanceFromStart = distanceFromStart
        self.timestamp = timestamp
        self.course = course
    }
}

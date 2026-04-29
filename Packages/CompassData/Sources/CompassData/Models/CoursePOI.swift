import Foundation
import SwiftData

/// A named point of interest on a course (water fountain, summit, viewpoint, …).
///
/// POIs are FIT `course_point` markers — separate from track waypoints. They
/// live at their own lat/lon (not snapped to the route) and become FIT
/// `course_point` messages on upload, which the watch displays as POI markers
/// during course navigation.
@Model
public final class CoursePOI {
    public var latitude: Double
    public var longitude: Double
    public var name: String
    /// FIT `course_point` type enum value. 0=generic, 1=summit, 3=water, 4=food, 5=danger, 9=first_aid, …
    public var coursePointType: Int
    /// Cumulative distance (m) along the route to the closest track point.
    /// Used for FIT `course_point.distance` so the watch knows where on the
    /// route to surface the POI.
    public var distanceFromStart: Double

    public var course: Course?

    public init(
        latitude: Double,
        longitude: Double,
        name: String,
        coursePointType: Int = 0,
        distanceFromStart: Double,
        course: Course? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
        self.coursePointType = coursePointType
        self.distanceFromStart = distanceFromStart
        self.course = course
    }
}

import Foundation
import SwiftData

/// Maps to HKWorkout
@Model
public final class Activity {
    #Unique<Activity>([\.id])

    public var id: UUID
    public var startDate: Date
    public var endDate: Date
    public var sport: Sport
    public var distance: Double
    public var duration: TimeInterval
    public var totalCalories: Double
    public var avgHeartRate: Int?
    public var maxHeartRate: Int?
    public var totalAscent: Double?
    public var totalDescent: Double?
    public var sourceFileName: String?

    @Relationship(deleteRule: .cascade, inverse: \TrackPoint.activity)
    public var trackPoints: [TrackPoint]

    public init(
        id: UUID = UUID(),
        startDate: Date,
        endDate: Date,
        sport: Sport,
        distance: Double,
        duration: TimeInterval,
        totalCalories: Double,
        avgHeartRate: Int? = nil,
        maxHeartRate: Int? = nil,
        totalAscent: Double? = nil,
        totalDescent: Double? = nil,
        sourceFileName: String? = nil,
        trackPoints: [TrackPoint] = []
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.sport = sport
        self.distance = distance
        self.duration = duration
        self.totalCalories = totalCalories
        self.avgHeartRate = avgHeartRate
        self.maxHeartRate = maxHeartRate
        self.totalAscent = totalAscent
        self.totalDescent = totalDescent
        self.sourceFileName = sourceFileName
        self.trackPoints = trackPoints
    }
}

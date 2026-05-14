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
    public var activeCalories: Double?
    public var avgHeartRate: Int?
    public var maxHeartRate: Int?
    public var totalAscent: Double?
    public var totalDescent: Double?
    public var sourceFileName: String?

    /// Pause intervals during the activity, in chronological order.
    /// Combined source: FIT `event` (timer stop ↔ start pairs) plus
    /// gap-detection over the trackpoint stream (gaps >30 s that aren't
    /// already inside a FIT-explicit pause).
    /// Parallel arrays for SwiftData friendliness — each (start[i], end[i])
    /// is one pause. Always have the same length.
    public var pauseStarts: [Date] = []
    public var pauseEnds: [Date] = []

    @Relationship(deleteRule: .cascade, inverse: \TrackPoint.activity)
    public var trackPoints: [TrackPoint]

    /// Pause intervals as a convenience computed pair. Empty if either
    /// underlying array is empty or they disagree in length (data drift).
    public var pauses: [DateInterval] {
        guard pauseStarts.count == pauseEnds.count else { return [] }
        return zip(pauseStarts, pauseEnds).compactMap { start, end in
            guard end > start else { return nil }
            return DateInterval(start: start, end: end)
        }
    }

    public init(
        id: UUID = UUID(),
        startDate: Date,
        endDate: Date,
        sport: Sport,
        distance: Double,
        duration: TimeInterval,
        activeCalories: Double? = nil,
        avgHeartRate: Int? = nil,
        maxHeartRate: Int? = nil,
        totalAscent: Double? = nil,
        totalDescent: Double? = nil,
        sourceFileName: String? = nil,
        pauseStarts: [Date] = [],
        pauseEnds: [Date] = [],
        trackPoints: [TrackPoint] = []
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.sport = sport
        self.distance = distance
        self.duration = duration
        self.activeCalories = activeCalories
        self.avgHeartRate = avgHeartRate
        self.maxHeartRate = maxHeartRate
        self.totalAscent = totalAscent
        self.totalDescent = totalDescent
        self.sourceFileName = sourceFileName
        self.pauseStarts = pauseStarts
        self.pauseEnds = pauseEnds
        self.trackPoints = trackPoints
    }
}

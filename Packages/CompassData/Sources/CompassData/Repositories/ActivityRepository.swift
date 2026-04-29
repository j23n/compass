import Foundation
import SwiftData

@MainActor
public final class ActivityRepository {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    /// Fetches activities whose startDate falls within the given date range.
    public func activitiesIn(dateRange: ClosedRange<Date>) throws -> [Activity] {
        let start = dateRange.lowerBound
        let end = dateRange.upperBound
        let predicate = #Predicate<Activity> { activity in
            activity.startDate >= start && activity.startDate <= end
        }
        let descriptor = FetchDescriptor<Activity>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    /// Fetches the most recent activities, limited by the given count.
    public func latestActivities(limit: Int) throws -> [Activity] {
        var descriptor = FetchDescriptor<Activity>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    /// Fetches a single activity by its unique identifier.
    public func activity(byId id: UUID) throws -> Activity? {
        let predicate = #Predicate<Activity> { activity in
            activity.id == id
        }
        var descriptor = FetchDescriptor<Activity>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

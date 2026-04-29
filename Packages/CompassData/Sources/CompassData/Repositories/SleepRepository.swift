import Foundation
import SwiftData

@MainActor
public final class SleepRepository {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    /// Fetches the most recent sleep session.
    public func latestSleep() throws -> SleepSession? {
        var descriptor = FetchDescriptor<SleepSession>(
            sortBy: [SortDescriptor(\.endDate, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Fetches sleep sessions whose startDate falls within the given date range.
    public func sleepSessionsIn(dateRange: ClosedRange<Date>) throws -> [SleepSession] {
        let start = dateRange.lowerBound
        let end = dateRange.upperBound
        let predicate = #Predicate<SleepSession> { session in
            session.startDate >= start && session.startDate <= end
        }
        let descriptor = FetchDescriptor<SleepSession>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }
}

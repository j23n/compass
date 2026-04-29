import Foundation
import SwiftData

@MainActor
public final class HealthMetricsRepository {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    /// Fetches heart rate samples within the given date range.
    public func heartRateSamples(in dateRange: ClosedRange<Date>) throws -> [HeartRateSample] {
        let start = dateRange.lowerBound
        let end = dateRange.upperBound
        let predicate = #Predicate<HeartRateSample> { sample in
            sample.timestamp >= start && sample.timestamp <= end
        }
        let descriptor = FetchDescriptor<HeartRateSample>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return try context.fetch(descriptor)
    }

    /// Fetches HRV samples within the given date range.
    public func hrvSamples(in dateRange: ClosedRange<Date>) throws -> [HRVSample] {
        let start = dateRange.lowerBound
        let end = dateRange.upperBound
        let predicate = #Predicate<HRVSample> { sample in
            sample.timestamp >= start && sample.timestamp <= end
        }
        let descriptor = FetchDescriptor<HRVSample>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return try context.fetch(descriptor)
    }

    /// Fetches stress samples within the given date range.
    public func stressSamples(in dateRange: ClosedRange<Date>) throws -> [StressSample] {
        let start = dateRange.lowerBound
        let end = dateRange.upperBound
        let predicate = #Predicate<StressSample> { sample in
            sample.timestamp >= start && sample.timestamp <= end
        }
        let descriptor = FetchDescriptor<StressSample>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return try context.fetch(descriptor)
    }

    /// Fetches body battery samples within the given date range.
    public func bodyBatterySamples(in dateRange: ClosedRange<Date>) throws -> [BodyBatterySample] {
        let start = dateRange.lowerBound
        let end = dateRange.upperBound
        let predicate = #Predicate<BodyBatterySample> { sample in
            sample.timestamp >= start && sample.timestamp <= end
        }
        let descriptor = FetchDescriptor<BodyBatterySample>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return try context.fetch(descriptor)
    }

    /// Fetches respiration samples within the given date range.
    public func respirationSamples(in dateRange: ClosedRange<Date>) throws -> [RespirationSample] {
        let start = dateRange.lowerBound
        let end = dateRange.upperBound
        let predicate = #Predicate<RespirationSample> { sample in
            sample.timestamp >= start && sample.timestamp <= end
        }
        let descriptor = FetchDescriptor<RespirationSample>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return try context.fetch(descriptor)
    }

    /// Fetches step counts within the given date range.
    public func stepCounts(in dateRange: ClosedRange<Date>) throws -> [StepCount] {
        let start = dateRange.lowerBound
        let end = dateRange.upperBound
        let predicate = #Predicate<StepCount> { sample in
            sample.date >= start && sample.date <= end
        }
        let descriptor = FetchDescriptor<StepCount>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.date)]
        )
        return try context.fetch(descriptor)
    }

    /// Returns the lowest resting heart rate sample for a given day.
    public func restingHeartRate(for date: Date) throws -> HeartRateSample? {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return nil
        }
        let restingContext = HeartRateContext.resting
        let predicate = #Predicate<HeartRateSample> { sample in
            sample.timestamp >= startOfDay
                && sample.timestamp < endOfDay
                && sample.context == restingContext
        }
        var descriptor = FetchDescriptor<HeartRateSample>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.bpm)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

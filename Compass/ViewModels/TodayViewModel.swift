import Foundation
import SwiftData
import CompassData

@Observable
@MainActor
final class TodayViewModel {
    private var context: ModelContext

    var activityMinutes: Int = 0
    var activityGoal: Int = 30
    var sleepHours: Double = 0
    var sleepGoal: Double = 8
    var bodyBatteryLevel: Int = 0
    var stressLevel: Int = 0

    var restingHeartRate: Int? = nil
    var heartRateSparkline: [Double] = []

    var latestSleep: SleepSession? = nil
    var todayActivities: [Activity] = []
    var bodyBatteryCurve: [(Date, Int)] = []
    var stressCurve: [(Date, Int)] = []

    init(context: ModelContext) {
        self.context = context
        refresh()
    }

    func refresh() {
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: startOfDay)!

        // Fetch today's activities
        let activityDescriptor = FetchDescriptor<Activity>(
            predicate: #Predicate { $0.startDate >= startOfDay },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        todayActivities = (try? context.fetch(activityDescriptor)) ?? []

        // Calculate activity minutes from today's step counts
        let stepDescriptor = FetchDescriptor<StepCount>(
            predicate: #Predicate { $0.date >= startOfDay }
        )
        let steps = (try? context.fetch(stepDescriptor)) ?? []
        activityMinutes = steps.reduce(0) { $0 + $1.intensityMinutes }

        // Latest sleep
        let sleepDescriptor = FetchDescriptor<SleepSession>(
            sortBy: [SortDescriptor(\.endDate, order: .reverse)]
        )
        var limitedSleepDescriptor = sleepDescriptor
        limitedSleepDescriptor.fetchLimit = 1
        latestSleep = (try? context.fetch(limitedSleepDescriptor))?.first
        if let sleep = latestSleep {
            sleepHours = sleep.endDate.timeIntervalSince(sleep.startDate) / 3600
        }

        // Heart rate samples last 24h (filter by resting context in-memory since
        // SwiftData predicates don't support enum member access without explicit base)
        let restingContext = HeartRateContext.resting
        let hrDescriptor = FetchDescriptor<HeartRateSample>(
            predicate: #Predicate { $0.timestamp >= yesterday && $0.context == restingContext },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let hrSamples = (try? context.fetch(hrDescriptor)) ?? []
        heartRateSparkline = hrSamples.map { Double($0.bpm) }
        restingHeartRate = hrSamples.last?.bpm

        // Body battery last 24h
        let bbDescriptor = FetchDescriptor<BodyBatterySample>(
            predicate: #Predicate { $0.timestamp >= yesterday },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let bbSamples = (try? context.fetch(bbDescriptor)) ?? []
        bodyBatteryCurve = bbSamples.map { ($0.timestamp, $0.level) }
        bodyBatteryLevel = bbSamples.last?.level ?? 0

        // Stress last 24h
        let stressDescriptor = FetchDescriptor<StressSample>(
            predicate: #Predicate { $0.timestamp >= yesterday },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let stressSamples = (try? context.fetch(stressDescriptor)) ?? []
        stressCurve = stressSamples.map { ($0.timestamp, $0.stressScore) }
        stressLevel = stressSamples.last?.stressScore ?? 0
    }
}

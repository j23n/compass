import Foundation
import SwiftData
import CompassData

enum TimeRange: String, CaseIterable, Sendable {
    case week = "Week"
    case month = "Month"
    case threeMonths = "3 Mo"
    case year = "Year"

    var days: Int {
        switch self {
        case .week: 7
        case .month: 30
        case .threeMonths: 90
        case .year: 365
        }
    }

    var startDate: Date {
        Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
    }
}

@Observable
@MainActor
final class HealthViewModel {
    private var context: ModelContext

    var selectedRange: TimeRange = .month {
        didSet { refresh() }
    }

    var restingHRData: [(Date, Int)] = []
    var hrvData: [(Date, Double)] = []
    var sleepData: [(Date, Double)] = []  // hours per night
    var bodyBatteryData: [(date: Date, min: Int, max: Int)] = []
    var stressData: [(Date, Double)] = []  // daily average
    var stepsData: [(Date, Int)] = []

    init(context: ModelContext) {
        self.context = context
        refresh()
    }

    func refresh() {
        let startDate = selectedRange.startDate

        // Resting HR - daily averages
        let restingContext = HeartRateContext.resting
        let hrDescriptor = FetchDescriptor<HeartRateSample>(
            predicate: #Predicate { $0.timestamp >= startDate && $0.context == restingContext },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let hrSamples = (try? context.fetch(hrDescriptor)) ?? []
        restingHRData = groupByDay(hrSamples.map { ($0.timestamp, $0.bpm) }) { values in
            values.reduce(0, +) / max(values.count, 1)
        }

        // HRV
        let hrvDescriptor = FetchDescriptor<HRVSample>(
            predicate: #Predicate { $0.timestamp >= startDate },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let hrvSamples = (try? context.fetch(hrvDescriptor)) ?? []
        hrvData = groupByDay(hrvSamples.map { ($0.timestamp, $0.rmssd) }) { values in
            values.reduce(0, +) / Double(max(values.count, 1))
        }

        // Sleep duration
        let sleepDescriptor = FetchDescriptor<SleepSession>(
            predicate: #Predicate { $0.startDate >= startDate },
            sortBy: [SortDescriptor(\.startDate)]
        )
        let sleepSessions = (try? context.fetch(sleepDescriptor)) ?? []
        sleepData = sleepSessions.map { ($0.startDate, $0.endDate.timeIntervalSince($0.startDate) / 3600) }

        // Body battery min/max
        let bbDescriptor = FetchDescriptor<BodyBatterySample>(
            predicate: #Predicate { $0.timestamp >= startDate },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let bbSamples = (try? context.fetch(bbDescriptor)) ?? []
        bodyBatteryData = groupByDayMinMax(bbSamples.map { ($0.timestamp, $0.level) })

        // Stress daily average
        let stressDescriptor = FetchDescriptor<StressSample>(
            predicate: #Predicate { $0.timestamp >= startDate },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let stressSamples = (try? context.fetch(stressDescriptor)) ?? []
        stressData = groupByDay(stressSamples.map { ($0.timestamp, Double($0.stressScore)) }) { values in
            values.reduce(0, +) / Double(max(values.count, 1))
        }

        // Steps
        let stepsDescriptor = FetchDescriptor<StepCount>(
            predicate: #Predicate { $0.date >= startDate },
            sortBy: [SortDescriptor(\.date)]
        )
        stepsData = ((try? context.fetch(stepsDescriptor)) ?? []).map { ($0.date, $0.steps) }
    }

    private func groupByDay<T: Numeric>(_ data: [(Date, T)], aggregate: ([T]) -> T) -> [(Date, T)] {
        let calendar = Calendar.current
        var groups: [Date: [T]] = [:]
        for (date, value) in data {
            let day = calendar.startOfDay(for: date)
            groups[day, default: []].append(value)
        }
        return groups.sorted { $0.key < $1.key }.map { ($0.key, aggregate($0.value)) }
    }

    private func groupByDayMinMax(_ data: [(Date, Int)]) -> [(date: Date, min: Int, max: Int)] {
        let calendar = Calendar.current
        var groups: [Date: [Int]] = [:]
        for (date, value) in data {
            let day = calendar.startOfDay(for: date)
            groups[day, default: []].append(value)
        }
        return groups.sorted { $0.key < $1.key }.map { (date: $0.key, min: $0.value.min() ?? 0, max: $0.value.max() ?? 0) }
    }
}

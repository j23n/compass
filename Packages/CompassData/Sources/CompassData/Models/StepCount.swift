import Foundation
import SwiftData

/// Maps to daily HKQuantitySample.stepCount
@Model
public final class StepCount {
    public var date: Date
    public var steps: Int
    public var intensityMinutes: Int
    public var calories: Double

    public init(
        date: Date,
        steps: Int,
        intensityMinutes: Int,
        calories: Double
    ) {
        self.date = date
        self.steps = steps
        self.intensityMinutes = intensityMinutes
        self.calories = calories
    }
}

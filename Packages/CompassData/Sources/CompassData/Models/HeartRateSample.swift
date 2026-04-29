import Foundation
import SwiftData

/// Maps to HKQuantityType.heartRate
@Model
public final class HeartRateSample {
    public var timestamp: Date
    public var bpm: Int
    public var context: HeartRateContext

    public init(
        timestamp: Date,
        bpm: Int,
        context: HeartRateContext
    ) {
        self.timestamp = timestamp
        self.bpm = bpm
        self.context = context
    }
}

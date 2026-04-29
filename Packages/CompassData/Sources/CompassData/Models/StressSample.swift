import Foundation
import SwiftData

/// Custom metric - no direct HealthKit equivalent.
/// Stress score ranges from 0 (no stress) to 100 (maximum stress).
@Model
public final class StressSample {
    public var timestamp: Date
    public var stressScore: Int

    public init(
        timestamp: Date,
        stressScore: Int
    ) {
        self.timestamp = timestamp
        self.stressScore = max(0, min(100, stressScore))
    }
}

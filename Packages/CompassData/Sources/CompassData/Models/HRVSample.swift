import Foundation
import SwiftData

/// Maps to HKQuantityType.heartRateVariabilitySDNN
@Model
public final class HRVSample {
    public var timestamp: Date
    public var rmssd: Double
    public var context: HeartRateContext

    public init(
        timestamp: Date,
        rmssd: Double,
        context: HeartRateContext
    ) {
        self.timestamp = timestamp
        self.rmssd = rmssd
        self.context = context
    }
}

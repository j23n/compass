import Foundation
import SwiftData

/// Maps to HKQuantityType.respiratoryRate
@Model
public final class RespirationSample {
    public var timestamp: Date
    public var breathsPerMinute: Double

    public init(
        timestamp: Date,
        breathsPerMinute: Double
    ) {
        self.timestamp = timestamp
        self.breathsPerMinute = breathsPerMinute
    }
}

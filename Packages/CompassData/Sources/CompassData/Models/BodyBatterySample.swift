import Foundation
import SwiftData

/// Custom metric - no direct HealthKit equivalent.
/// Body battery level ranges from 0 (depleted) to 100 (fully charged).
@Model
public final class BodyBatterySample {
    public var timestamp: Date
    public var level: Int

    public init(
        timestamp: Date,
        level: Int
    ) {
        self.timestamp = timestamp
        self.level = max(0, min(100, level))
    }
}

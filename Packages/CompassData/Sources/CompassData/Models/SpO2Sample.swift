import Foundation
import SwiftData

/// Maps to HKQuantityTypeIdentifier.oxygenSaturation
@Model
public final class SpO2Sample {
    public var timestamp: Date
    /// SpO₂ percentage (0–100).
    public var percent: Int

    public init(
        timestamp: Date,
        percent: Int
    ) {
        self.timestamp = timestamp
        self.percent = percent
    }
}

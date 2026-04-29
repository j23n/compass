import Foundation
import SwiftData

/// An intraday step sample captured from a monitoring FIT interval (~1 min each).
/// Enables per-hour step charts on the Today screen.
@Model
public final class StepSample {
    public var timestamp: Date
    public var steps: Int

    public init(timestamp: Date, steps: Int) {
        self.timestamp = timestamp
        self.steps = steps
    }
}

import Foundation
import SwiftData

/// Per-interval active-intensity record from a monitoring FIT file (~1 min each).
/// Enables 4-hour hourly active-minutes charts on the Today screen.
/// Daily aggregates remain in StepCount.intensityMinutes for the headline total.
@Model
public final class IntensitySample {
    public var uuid: UUID = UUID()
    @Attribute(.unique) public var timestamp: Date
    public var minutes: Int

    public init(timestamp: Date, minutes: Int) {
        self.timestamp = timestamp
        self.minutes = minutes
    }
}

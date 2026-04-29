import Foundation
import SwiftData

/// Maps to HKCategorySample (sleep analysis sub-samples)
@Model
public final class SleepStage {
    public var startDate: Date
    public var endDate: Date
    public var stage: SleepStageType

    public var session: SleepSession?

    public init(
        startDate: Date,
        endDate: Date,
        stage: SleepStageType,
        session: SleepSession? = nil
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.stage = stage
        self.session = session
    }
}

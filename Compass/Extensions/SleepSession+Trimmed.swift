import Foundation
import CompassData

extension SleepSession {
    /// Stages clipped to `[startDate, endDate]` with any leading or trailing
    /// awake records dropped. The session bounds are already trimmed by
    /// `SleepStageResult.trimmedBounds` during sync, but the raw stage records
    /// remain so we filter at render time.
    var trimmedStages: [SleepStage] {
        let inBounds = stages
            .filter { $0.endDate > startDate && $0.startDate < endDate }
            .sorted { $0.startDate < $1.startDate }
        var trimmed = Array(inBounds.drop(while: { $0.stage == .awake }))
        while trimmed.last?.stage == .awake { trimmed.removeLast() }
        return trimmed
    }
}

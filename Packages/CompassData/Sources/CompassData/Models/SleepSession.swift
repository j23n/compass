import Foundation
import SwiftData

/// Maps to HKCategoryTypeIdentifier.sleepAnalysis
@Model
public final class SleepSession {
    #Unique<SleepSession>([\.id])

    public var id: UUID
    public var startDate: Date
    public var endDate: Date
    public var score: Int?
    /// Overall recovery score from msg 276 (sleep_assessment), 0-100.
    public var recoveryScore: Int?
    /// Sleep quality qualifier from msg 276 (e.g., "excellent", "good", "fair", "poor").
    public var qualifier: String?

    @Relationship(deleteRule: .cascade, inverse: \SleepStage.session)
    public var stages: [SleepStage]

    public init(
        id: UUID = UUID(),
        startDate: Date,
        endDate: Date,
        score: Int? = nil,
        recoveryScore: Int? = nil,
        qualifier: String? = nil,
        stages: [SleepStage] = []
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.score = score
        self.recoveryScore = recoveryScore
        self.qualifier = qualifier
        self.stages = stages
    }
}

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

    @Relationship(deleteRule: .cascade, inverse: \SleepStage.session)
    public var stages: [SleepStage]

    public init(
        id: UUID = UUID(),
        startDate: Date,
        endDate: Date,
        score: Int? = nil,
        stages: [SleepStage] = []
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.score = score
        self.stages = stages
    }
}

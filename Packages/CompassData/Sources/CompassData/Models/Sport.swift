import Foundation

public enum Sport: String, Codable, Sendable, CaseIterable {
    case running, cycling, swimming, hiking, walking, strength, yoga, cardio, other

    public var displayName: String {
        rawValue.capitalized
    }

    public var systemImage: String {
        switch self {
        case .running: "figure.run"
        case .cycling: "bicycle"
        case .swimming: "figure.pool.swim"
        case .hiking: "figure.hiking"
        case .walking: "figure.walk"
        case .strength: "dumbbell"
        case .yoga:    "figure.yoga"
        case .cardio:  "heart.circle"
        case .other:   "figure.mixed.cardio"
        }
    }

    /// FIT SDK `sport` enum value, used in FIT `course` and `session` messages.
    public var fitSportCode: UInt8 {
        switch self {
        case .running:  1
        case .cycling:  2
        case .swimming: 5
        case .walking:  11
        case .hiking:   17
        case .strength: 10  // training
        case .yoga:     43
        case .cardio:   0   // generic
        case .other:    0   // generic
        }
    }
}

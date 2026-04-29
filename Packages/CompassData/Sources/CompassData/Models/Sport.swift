import Foundation

public enum Sport: String, Codable, Sendable, CaseIterable {
    case running, cycling, swimming, hiking, walking, strength, cardio, other

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
        case .cardio: "heart.circle"
        case .other: "figure.mixed.cardio"
        }
    }
}

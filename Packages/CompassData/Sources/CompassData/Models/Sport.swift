import Foundation

public enum Sport: String, Codable, Sendable, CaseIterable {
    case running, cycling, swimming, hiking, walking, strength, yoga, cardio, other
    case rowing, kayaking, skiing, snowboarding, sup, climbing, boating, mtb

    public var displayName: String {
        switch self {
        case .mtb: "Mountain Biking"
        case .sup: "SUP"
        default:   rawValue.capitalized
        }
    }

    public var systemImage: String {
        switch self {
        case .running:      "figure.run"
        case .cycling:      "bicycle"
        case .mtb:          "bicycle"
        case .swimming:     "figure.pool.swim"
        case .hiking:       "figure.hiking"
        case .walking:      "figure.walk"
        case .strength:     "dumbbell"
        case .yoga:         "figure.yoga"
        case .cardio:       "heart.circle"
        case .rowing:       "oar.2.crossed"
        case .kayaking:     "figure.water.fitness"
        case .skiing:       "figure.skiing.downhill"
        case .snowboarding: "figure.snowboarding"
        case .sup:          "figure.surfing"
        case .climbing:     "figure.climbing"
        case .boating:      "sailboat"
        case .other:        "figure.mixed.cardio"
        }
    }

    /// FIT SDK `sport` enum value, used in FIT `course` and `session` messages.
    /// Only used by `CourseFITEncoder`; activity parsing uses string names from FitFileParser.
    public var fitSportCode: UInt8 {
        switch self {
        case .running:      1
        case .cycling, .mtb: 2
        case .swimming:     5
        case .walking:      11
        case .skiing:       13
        case .snowboarding: 14
        case .rowing:       15
        case .hiking:       17
        case .boating:      23
        case .climbing:     31
        case .sup:          37
        case .kayaking:     41
        case .yoga:         43
        case .strength:     10  // training
        case .cardio:       0   // generic
        case .other:        0   // generic
        }
    }
}

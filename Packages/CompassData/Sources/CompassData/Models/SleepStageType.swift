import Foundation

public enum SleepStageType: String, Codable, Sendable {
    case awake, light, deep, rem

    public var displayName: String {
        switch self {
        case .awake: "Awake"
        case .light: "Light"
        case .deep: "Deep"
        case .rem: "REM"
        }
    }

    public var sortOrder: Int {
        switch self {
        case .deep: 0
        case .rem: 1
        case .light: 2
        case .awake: 3
        }
    }
}

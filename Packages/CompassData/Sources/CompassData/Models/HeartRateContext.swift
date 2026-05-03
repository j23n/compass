import Foundation

public enum HeartRateContext: String, Codable, Sendable {
    case resting, active, sleep, unspecified
}

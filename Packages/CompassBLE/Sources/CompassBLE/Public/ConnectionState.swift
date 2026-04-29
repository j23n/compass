import Foundation

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(deviceName: String)
    case failed(String)

    public static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected): true
        case (.connecting, .connecting): true
        case (.connected(let a), .connected(let b)): a == b
        case (.failed(let a), .failed(let b)): a == b
        default: false
        }
    }
}

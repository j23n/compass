import Foundation

/// Encodes per-device quirks that the parsers and sync layer need to handle.
///
/// Known profiles:
/// - Instinct Solar 1G (`productID = 3466`): `.instinct20ByteBlob`, `sedentary = 8`
/// - Default (all others): `.standard`, `sedentary = 7`
public struct DeviceProfile: Sendable, Equatable {
    public var productID: UInt16
    public var sleepMsg274Format: SleepMsg274Format
    public var sedentaryActivityType: UInt8

    public init(
        productID: UInt16,
        sleepMsg274Format: SleepMsg274Format,
        sedentaryActivityType: UInt8
    ) {
        self.productID = productID
        self.sleepMsg274Format = sleepMsg274Format
        self.sedentaryActivityType = sedentaryActivityType
    }

    public static let `default` = DeviceProfile(
        productID: 0,
        sleepMsg274Format: .standard,
        sedentaryActivityType: 7
    )

    public static let instinctSolar1G = DeviceProfile(
        productID: 3466,
        sleepMsg274Format: .instinct20ByteBlob,
        sedentaryActivityType: 8
    )

    public static func profile(for productID: UInt16) -> DeviceProfile {
        switch productID {
        case 3466: return .instinctSolar1G
        default:   return .default
        }
    }
}

public enum SleepMsg274Format: Sendable, Equatable {
    /// Standard FIT layout: field 0 = uint8 level (0=unmeasurable, 1=awake, 2=light, 3=deep, 4=rem),
    /// field 253 = timestamp.
    case standard

    /// Instinct Solar 1G firmware 19.1: 20-byte opaque blob per record.
    /// Byte 19 = sleep stage (81=deep, 82=light, 83=REM, 84-85=awake).
    case instinct20ByteBlob
}

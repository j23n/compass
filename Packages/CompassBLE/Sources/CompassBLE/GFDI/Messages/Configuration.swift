import Foundation

/// CONFIGURATION (5050 / 0x13BA) — capability negotiation.
///
/// Both the watch (incoming) and host (outgoing) use the same payload format:
/// ```
/// [length: UInt8]            // number of capability bytes (0..255)
/// [capabilityBytes: N]       // bitmask
/// ```
///
/// Reference: Gadgetbridge `ConfigurationMessage.java`
public struct ConfigurationMessage: Sendable {

    /// Raw capability bytes — bitmask whose meaning is documented in
    /// Gadgetbridge `GarminCapability`. We don't interpret individual bits.
    public let capabilityBytes: Data

    public init(capabilityBytes: Data) {
        self.capabilityBytes = capabilityBytes
    }

    public static func decode(from data: Data) throws -> ConfigurationMessage {
        var reader = ByteReader(data: data)
        let length = Int(try reader.readUInt8())
        let bytes = length > 0 ? try reader.readBytes(length) : Data()
        return ConfigurationMessage(capabilityBytes: bytes)
    }

    public func toMessage() -> GFDIMessage {
        var payload = Data()
        let count = min(capabilityBytes.count, 255)
        payload.append(UInt8(count))
        payload.append(capabilityBytes.prefix(count))
        return GFDIMessage(type: .configuration, payload: payload)
    }

    /// Default capability bitmask. Gadgetbridge's `OUR_CAPABILITIES` is 15
    /// bytes covering the 120-entry `GarminCapability` enum (1 bit per
    /// ordinal, LSB-first, byte 0 holds ordinals 0..7).
    /// See `docs/gadgetbridge-instinct-pairing.md` §11. We claim everything;
    /// the specific bits the Instinct cares about for pairing aren't
    /// publicly documented, so all-1s is the safest superset.
    public static func ourCapabilities() -> ConfigurationMessage {
        let bytes = Data(repeating: 0xFF, count: 15)
        return ConfigurationMessage(capabilityBytes: bytes)
    }
}

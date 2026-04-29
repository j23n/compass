import Foundation

/// AUTH_NEGOTIATION (5101 / 0x13ED) — sent by the watch to negotiate auth.
/// The host responds via `GFDIResponse` echoing the unknown byte and the
/// auth flags, plus a `GUESS_OK` byte.
///
/// Wire format (incoming payload):
/// ```
/// [unknown: UInt8]
/// [authFlags: UInt32 LE]
/// ```
///
/// Reference: Gadgetbridge `AuthNegotiationMessage.java`,
///            `AuthNegotiationStatusMessage.java`
public struct AuthNegotiationMessage: Sendable {

    public let unknown: UInt8
    public let authFlags: UInt32

    public init(unknown: UInt8, authFlags: UInt32) {
        self.unknown = unknown
        self.authFlags = authFlags
    }

    public static func decode(from data: Data) throws -> AuthNegotiationMessage {
        var reader = ByteReader(data: data)
        let unknown = try reader.readUInt8()
        // Some devices may not include the flags field — default to 0.
        let flags: UInt32 = reader.remaining >= 4 ? try reader.readUInt32LE() : 0
        return AuthNegotiationMessage(unknown: unknown, authFlags: flags)
    }
}

/// Builds the RESPONSE the host sends after AUTH_NEGOTIATION.
///
/// Wire format (additional payload, after originalType + status bytes):
/// ```
/// [authNegStatus: UInt8]   // 0 = GUESS_OK, 1 = GUESS_KO
/// [unknown: UInt8]         // echoed from incoming
/// [authFlags: UInt32 LE]   // echoed from incoming
/// ```
public struct AuthNegotiationStatusResponse: Sendable {

    public enum AuthNegotiationStatus: UInt8, Sendable {
        case guessOk = 0
        case guessKo = 1
    }

    public let authNegStatus: AuthNegotiationStatus
    public let unknown: UInt8
    public let authFlags: UInt32

    public init(
        authNegStatus: AuthNegotiationStatus = .guessOk,
        unknown: UInt8,
        authFlags: UInt32
    ) {
        self.authNegStatus = authNegStatus
        self.unknown = unknown
        self.authFlags = authFlags
    }

    /// Build an ACK response for an incoming AuthNegotiation, echoing fields back.
    public init(echoing message: AuthNegotiationMessage,
                status: AuthNegotiationStatus = .guessOk) {
        self.authNegStatus = status
        self.unknown = message.unknown
        self.authFlags = message.authFlags
    }

    public func toMessage() -> GFDIMessage {
        var extra = Data()
        extra.append(authNegStatus.rawValue)
        extra.append(unknown)
        extra.appendUInt32LE(authFlags)
        return GFDIResponse(
            originalType: .authNegotiation,
            status: .ack,
            additionalPayload: extra
        ).toMessage()
    }
}

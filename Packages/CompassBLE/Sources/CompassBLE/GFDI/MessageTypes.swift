import Foundation

/// Known GFDI message type codes (Gadgetbridge `GarminMessage` enum).
///
/// Wire format encoding:
/// - Direct: 16-bit LE matching the decimal type value (e.g., 5024 = 0x13A0).
/// - Compact: if bit 15 is set, actual type = `(raw & 0xFF) + 5000`. Decoded
///   transparently in ``GFDIMessage/decode(from:)``.
public enum GFDIMessageType: UInt16, Sendable, Equatable {

    /// Generic ACK/NACK response message. Carries the original message type
    /// and a status byte plus message-specific payload.
    case response = 0x1388                  // 5000

    case downloadRequest = 0x138A           // 5002
    case uploadRequest = 0x138B             // 5003
    case fileTransferData = 0x138C          // 5004
    case createFile = 0x138D                // 5005
    case directoryFilter = 0x138F           // 5007
    case setFileFlag = 0x1390               // 5008
    case fitDefinition = 0x1393             // 5011
    case fitData = 0x1394                   // 5012
    case weatherRequest = 0x1396            // 5014
    case deviceInformation = 0x13A0         // 5024
    case deviceSettings = 0x13A2            // 5026
    case systemEvent = 0x13A6               // 5030
    case supportedFileTypesRequest = 0x13A7 // 5031
    case notificationUpdate = 0x13A9        // 5033
    case notificationControl = 0x13AA       // 5034
    case notificationData = 0x13AB          // 5035
    case notificationSubscription = 0x13AC  // 5036
    case synchronization = 0x13AD           // 5037
    case findMyPhoneRequest = 0x13AF        // 5039
    case findMyPhoneCancel = 0x13B0         // 5040
    case musicControl = 0x13B1              // 5041
    case musicControlCapabilities = 0x13B2  // 5042
    case protobufRequest = 0x13B3           // 5043
    case protobufResponse = 0x13B4          // 5044
    case musicControlEntityUpdate = 0x13B9  // 5049
    case configuration = 0x13BA             // 5050
    case currentTimeRequest = 0x13BC        // 5052
    case authNegotiation = 0x13ED           // 5101
}

import Foundation

/// DEVICE_INFORMATION (5024 / 0x13A0) — sent by the watch as the first GFDI
/// message after the BLE connection is up.
///
/// Wire format (payload, all fields little-endian):
/// ```
/// [protocolVersion: UInt16]
/// [productNumber:   UInt16]
/// [unitNumber:      UInt32]
/// [softwareVersion: UInt16]
/// [maxPacketSize:   UInt16]
/// [bluetoothFriendlyName: length-prefixed UTF-8 string]
/// [deviceName:            length-prefixed UTF-8 string]
/// [deviceModel:           length-prefixed UTF-8 string]
/// ```
///
/// Reference: Gadgetbridge `DeviceInformationMessage.java#parseIncoming`
public struct DeviceInformationMessage: Sendable {
    public let protocolVersion: UInt16
    public let productNumber: UInt16
    public let unitNumber: UInt32
    public let softwareVersion: UInt16
    public let maxPacketSize: UInt16
    public let bluetoothFriendlyName: String
    public let deviceName: String
    public let deviceModel: String

    public init(
        protocolVersion: UInt16,
        productNumber: UInt16,
        unitNumber: UInt32,
        softwareVersion: UInt16,
        maxPacketSize: UInt16,
        bluetoothFriendlyName: String,
        deviceName: String,
        deviceModel: String
    ) {
        self.protocolVersion = protocolVersion
        self.productNumber = productNumber
        self.unitNumber = unitNumber
        self.softwareVersion = softwareVersion
        self.maxPacketSize = maxPacketSize
        self.bluetoothFriendlyName = bluetoothFriendlyName
        self.deviceName = deviceName
        self.deviceModel = deviceModel
    }

    public static func decode(from data: Data) throws -> DeviceInformationMessage {
        var reader = ByteReader(data: data)
        let protocolVersion = try reader.readUInt16LE()
        let productNumber = try reader.readUInt16LE()
        let unitNumber = try reader.readUInt32LE()
        let softwareVersion = try reader.readUInt16LE()
        let maxPacketSize = try reader.readUInt16LE()
        let btName = try reader.readLengthPrefixedString()
        let deviceName = try reader.readLengthPrefixedString()
        let deviceModel = try reader.readLengthPrefixedString()
        return DeviceInformationMessage(
            protocolVersion: protocolVersion,
            productNumber: productNumber,
            unitNumber: unitNumber,
            softwareVersion: softwareVersion,
            maxPacketSize: maxPacketSize,
            bluetoothFriendlyName: btName,
            deviceName: deviceName,
            deviceModel: deviceModel
        )
    }
}

/// Builds the RESPONSE (5000) the host sends after receiving DEVICE_INFORMATION.
///
/// The status response embeds the host's own device info, mirroring
/// Gadgetbridge `DeviceInformationMessage#generateOutgoing`:
/// ```
/// [originalType: UInt16 = 5024]
/// [status: UInt8 = 0 (ACK)]
/// [hostProtocolVersion:   UInt16]
/// [hostProductNumber:     UInt16]
/// [hostUnitNumber:        UInt32]
/// [hostSoftwareVersion:   UInt16]
/// [hostMaxPacketSize:     UInt16]
/// [bluetoothName:    length-prefixed UTF-8 string]
/// [manufacturer:     length-prefixed UTF-8 string]
/// [device:           length-prefixed UTF-8 string]
/// [protocolFlags:    UInt8]
/// ```
public struct DeviceInformationResponse: Sendable {
    public let protocolVersion: UInt16
    public let productNumber: UInt16
    public let unitNumber: UInt32
    public let softwareVersion: UInt16
    public let maxPacketSize: UInt16
    public let bluetoothName: String
    public let manufacturer: String
    public let device: String
    public let protocolFlags: UInt8

    /// Defaults match the values Gadgetbridge sends.
    public init(
        protocolVersion: UInt16 = 150,
        productNumber: UInt16 = 0xFFFF,
        unitNumber: UInt32 = 0xFFFFFFFF,
        softwareVersion: UInt16 = 7791,
        maxPacketSize: UInt16 = 0xFFFF,
        bluetoothName: String = "Compass",
        manufacturer: String = "Apple",
        device: String = "iPhone",
        protocolFlags: UInt8 = 0
    ) {
        self.protocolVersion = protocolVersion
        self.productNumber = productNumber
        self.unitNumber = unitNumber
        self.softwareVersion = softwareVersion
        self.maxPacketSize = maxPacketSize
        self.bluetoothName = bluetoothName
        self.manufacturer = manufacturer
        self.device = device
        self.protocolFlags = protocolFlags
    }

    /// Build a response echoing the convention used by Gadgetbridge:
    /// `protocolFlags = (incoming protocol version is in 100..199) ? 1 : 0`.
    public init(replyingTo incoming: DeviceInformationMessage) {
        self.init(
            protocolFlags: incoming.protocolVersion / 100 == 1 ? 1 : 0
        )
    }

    public func toMessage() -> GFDIMessage {
        var extra = Data()
        extra.appendUInt16LE(protocolVersion)
        extra.appendUInt16LE(productNumber)
        extra.appendUInt32LE(unitNumber)
        extra.appendUInt16LE(softwareVersion)
        extra.appendUInt16LE(maxPacketSize)
        extra.appendLengthPrefixedString(bluetoothName)
        extra.appendLengthPrefixedString(manufacturer)
        extra.appendLengthPrefixedString(device)
        extra.append(protocolFlags)
        return GFDIResponse(
            originalType: .deviceInformation,
            status: .ack,
            additionalPayload: extra
        ).toMessage()
    }
}

// MARK: - Data Helpers

extension Data {
    /// Append a UInt16 in little-endian byte order.
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    /// Append a UInt32 in little-endian byte order.
    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    /// Append a length-prefixed UTF-8 string (1-byte length, no terminator).
    /// Throws nothing but truncates strings longer than 255 bytes.
    mutating func appendLengthPrefixedString(_ value: String) {
        var bytes = Array(value.utf8)
        if bytes.count > 255 { bytes = Array(bytes.prefix(255)) }
        append(UInt8(bytes.count))
        append(contentsOf: bytes)
    }
}

import Foundation

/// SUPPORTED_FILE_TYPES_REQUEST (5031 / 0x13A7).
/// Empty payload — just asks the watch to enumerate the file types it supports.
///
/// Reference: Gadgetbridge `SupportedFileTypesMessage.java`,
///            `docs/gadgetbridge-instinct-pairing.md` §10 step 10.
public struct SupportedFileTypesRequestMessage: Sendable {
    public init() {}

    public func toMessage() -> GFDIMessage {
        // No payload — just length(2) + type(2) + CRC(2) = 6 bytes total.
        GFDIMessage(type: .supportedFileTypesRequest, payload: Data())
    }
}

/// SET_DEVICE_SETTINGS (5026 / 0x13A2).
///
/// Wire format (payload):
/// ```
/// [count: UInt8]
/// [
///   [settingType: UInt8]      // GarminDeviceSetting ordinal
///   [valueLength: UInt8]      // 1 for Bool, 4 for Int, N for String
///   [value: valueLength bytes]
/// ] × count
/// ```
///
/// Reference: Gadgetbridge `SetDeviceSettingsMessage.java`.
public struct SetDeviceSettingsMessage: Sendable {

    /// `GarminDeviceSetting` enum ordinals from Gadgetbridge.
    public enum SettingType: UInt8, Sendable {
        case deviceName                = 0
        case currentTime               = 1
        case daylightSavingsTimeOffset = 2
        case timeZoneOffset            = 3
        case nextDaylightSavingsStart  = 4
        case nextDaylightSavingsEnd    = 5
        case autoUploadEnabled         = 6
        case weatherConditionsEnabled  = 7
        case weatherAlertsEnabled      = 8
    }

    public enum SettingValue: Sendable {
        case bool(Bool)
        case int32(Int32)
        case string(String)

        var encodedBytes: Data {
            var d = Data()
            switch self {
            case .bool(let v):
                d.append(0x01) // length = 1
                d.append(v ? 0x01 : 0x00)
            case .int32(let v):
                d.append(0x04) // length = 4
                let u = UInt32(bitPattern: v)
                d.appendUInt32LE(u)
            case .string(let s):
                d.appendLengthPrefixedString(s)
            }
            return d
        }
    }

    public let settings: [(SettingType, SettingValue)]

    public init(settings: [(SettingType, SettingValue)]) {
        self.settings = settings
    }

    /// Defaults Gadgetbridge sends during `completeInitialization()`:
    /// `AUTO_UPLOAD_ENABLED=true`, `WEATHER_CONDITIONS_ENABLED=true`,
    /// `WEATHER_ALERTS_ENABLED=false`.
    public static func defaults() -> SetDeviceSettingsMessage {
        SetDeviceSettingsMessage(settings: [
            (.autoUploadEnabled,        .bool(true)),
            (.weatherConditionsEnabled, .bool(true)),
            (.weatherAlertsEnabled,     .bool(false)),
        ])
    }

    public func toMessage() -> GFDIMessage {
        var payload = Data()
        payload.append(UInt8(min(settings.count, 255)))
        for (type, value) in settings {
            payload.append(type.rawValue)
            payload.append(value.encodedBytes)
        }
        return GFDIMessage(type: .deviceSettings, payload: payload)
    }
}

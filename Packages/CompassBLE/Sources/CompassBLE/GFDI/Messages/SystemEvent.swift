import Foundation

/// SYSTEM_EVENT (5030 / 0x13A6) — host sends these to drive lifecycle
/// transitions (pair complete, sync complete, time updated, etc.).
///
/// Wire format (payload, 2 bytes total for the value-bearing case):
/// ```
/// [eventType: UInt8]
/// [eventValue: UInt8]   // 0 for unparameterised events; complete message is 8 bytes
/// ```
///
/// Reference: Gadgetbridge `SystemEventMessage.java`,
///            `docs/gadgetbridge-instinct-pairing.md` §13.
public struct SystemEventMessage: Sendable {

    public enum EventType: UInt8, Sendable {
        case syncComplete = 0
        case syncFail = 1
        case factoryReset = 2
        case pairStart = 3
        case pairComplete = 4
        case pairFail = 5
        case hostDidEnterForeground = 6
        case hostDidEnterBackground = 7
        case syncReady = 8
        case newDownloadAvailable = 9
        case deviceSoftwareUpdate = 10
        case deviceDisconnect = 11
        case tutorialComplete = 12
        case setupWizardStart = 13
        case setupWizardComplete = 14
        case setupWizardSkipped = 15
        case timeUpdated = 16
    }

    public let eventType: EventType
    public let eventValue: UInt8

    public init(eventType: EventType, eventValue: UInt8 = 0) {
        self.eventType = eventType
        self.eventValue = eventValue
    }

    public func toMessage() -> GFDIMessage {
        var payload = Data()
        payload.append(eventType.rawValue)
        payload.append(eventValue)
        return GFDIMessage(type: .systemEvent, payload: payload)
    }
}

# GFDI Pairing Handshake

This document covers the Compass side of pairing **after** the BLE link is
up and the V2 Multi-Link transport has assigned a GFDI handle. For the
underlying ML init (CLOSE_ALL → REGISTER_ML), see
`docs/garmin/transport/`. For the byte-level reference walkthrough see
`docs/garmin/references/gadgetbridge-pairing.md`.

The handshake is **device-initiated**: the watch sends DEVICE_INFORMATION
first; Compass never speaks until it has parsed that frame.

Compass: `GarminDeviceManager.swift:13-19` (overview comment) and
`GarminDeviceManager.swift:437-497` (`runHandshake`).

## Sequence

```
Watch                                       Compass (phone)
  |                                                |
  |  -- BLE connect, GATT discovery, notify on -- |
  |                                                |
  |  ML: CLOSE_ALL_REQ / RESP, REGISTER_ML(GFDI)  |
  |  (handled by MultiLinkTransport)              |
  |                                                |
  |  --- DEVICE_INFORMATION (5024) ---->           | (1) waitForMessage(deviceInformation)
  |                                                |
  |  <-- RESPONSE(5024, ACK)  [9 bytes, bare] --   | (2) GarminDeviceManager.swift:445-447
  |                                                |     ** Compass deviation: NO host echo **
  |                                                |
  |  --- CONFIGURATION (5050) -------->            | (3) waitForMessage(configuration)
  |                                                |
  |  <-- RESPONSE(5050, ACK) ----------            | (4) bare ACK
  |  <-- CONFIGURATION (15 × 0xFF) ----            | (5) ourCapabilities()
  |                                                |
  |   .. AUTH_NEGOTIATION may arrive any time ..  | (handled async, NOT awaited)
  |                                                |
  |  <-- SUPPORTED_FILE_TYPES_REQUEST (5031) ---   | (6) post-init burst begins
  |  <-- DEVICE_SETTINGS (5026 TLV) ------------   | (7)
  |  <-- SYSTEM_EVENT(SYNC_READY=8) ------------   | (8)
  |  <-- SYSTEM_EVENT(PAIR_COMPLETE=4) ---------   | (9)
  |  <-- SYSTEM_EVENT(SYNC_COMPLETE=0) ---------   | (10)
  |  <-- SYSTEM_EVENT(SETUP_WIZARD_COMPLETE=14)    | (11)
  |                                                |
  |  --- post-pair stream begins ----->            | (12) handled by handleUnsolicited
  |     CURRENT_TIME_REQUEST                       |
  |     PROTOBUF_REQUEST                           |
  |     MUSIC_CONTROL_CAPABILITIES                 |
  |     NOTIFICATION_SUBSCRIPTION                  |
  |     SYNCHRONIZATION                            |
  |     WEATHER_REQUEST                            |
```

## Step-by-Step

### (1) Wait for DEVICE_INFORMATION (5024)

```swift
// GarminDeviceManager.swift:438-443
let devInfoMsg = try await gfdiClient.waitForMessage(
    type: .deviceInformation, timeout: .seconds(15))
let devInfo = try DeviceInformationMessage.decode(from: devInfoMsg.payload)
```

The watch sends DEVICE_INFORMATION (`Compass: DeviceInformation.swift:19-70`)
including its `protocolVersion`, `productNumber`, `unitNumber`,
`softwareVersion`, `maxPacketSize`, and three length-prefixed strings
(bluetooth name, device name, device model). Compass stores `maxPacketSize`
for use by the file-transfer layer.

### (2) Reply with bare RESPONSE (5000)

**Compass deviation from the doc-only echo path:** Compass sends a
9-byte bare ACK rather than echoing host info, matching observed
Gadgetbridge runtime behaviour.

```swift
// GarminDeviceManager.swift:445-447
let devInfoAck = GFDIResponse(originalType: .deviceInformation, status: .ack)
try await gfdiClient.send(message: devInfoAck.toMessage())
```

The full host-echo response *exists* in `DeviceInformationResponse`
(`DeviceInformation.swift:89-148`) and is exercised by the unit tests in
`GFDIMessageTests.swift`, but it is **not** used at runtime. Sending the
echo did not break pairing in testing, but the bare ACK is what matches
shipped Gadgetbridge against the Instinct Solar 1G.

### (3-5) CONFIGURATION exchange

```swift
// GarminDeviceManager.swift:449-459
let configMsg = try await gfdiClient.waitForMessage(type: .configuration, ...)
// ACK then echo our own capabilities
try await gfdiClient.send(message: GFDIResponse(originalType: .configuration, status: .ack).toMessage())
try await gfdiClient.send(message: ConfigurationMessage.ourCapabilities().toMessage())
```

`ourCapabilities()` produces 15 bytes of `0xFF` — claim every
`GarminCapability` ordinal (`Configuration.swift:43-46`).

### AUTH_NEGOTIATION is **not** awaited

**Compass deviation:** Gadgetbridge's `completeInitialization()` runs
immediately after CONFIGURATION with no idle gap. Adding a 3-second wait
for AUTH_NEGOTIATION caused the Instinct Solar 1G to disconnect — its
session timeout is shorter than 3 s. Instead, AUTH_NEGOTIATION is handled
asynchronously through `handleUnsolicited`:

```swift
// GarminDeviceManager.swift:203-208
case .authNegotiation:
    if let auth = try? AuthNegotiationMessage.decode(from: msg.payload) {
        let ack = AuthNegotiationStatusResponse(echoing: auth, status: .guessOk)
        try? await client.send(message: ack.toMessage())
    }
```

See the comment block at `GarminDeviceManager.swift:461-469`.

### (6-11) Post-Init Burst — the order matters

```swift
// GarminDeviceManager.swift:484-494
try await gfdiClient.send(message: SupportedFileTypesRequestMessage().toMessage())
try await gfdiClient.send(message: SetDeviceSettingsMessage.defaults().toMessage())
try await gfdiClient.send(message: SystemEventMessage(eventType: .syncReady).toMessage())
try await gfdiClient.send(message: SystemEventMessage(eventType: .pairComplete).toMessage())
try await gfdiClient.send(message: SystemEventMessage(eventType: .syncComplete).toMessage())
try await gfdiClient.send(message: SystemEventMessage(eventType: .setupWizardComplete).toMessage())
```

Empirically, sending `SYNC_READY` *before* `SUPPORTED_FILE_TYPES_REQUEST`
caused the watch to disconnect cleanly. The watch's state machine waits
for the file-types probe before accepting any SYSTEM_EVENT.
See `GarminDeviceManager.swift:471-483`.

`DEVICE_SETTINGS` carries three booleans: `AUTO_UPLOAD_ENABLED=true`,
`WEATHER_CONDITIONS_ENABLED=true`, `WEATHER_ALERTS_ENABLED=false`
(`PostInit.swift:73-82`).

**Compass intentionally skips `TIME_UPDATED` (16).** Gadgetbridge sends it
with a 4-byte Garmin-epoch timestamp when its `syncTime` pref is set; the
value field is a different size from the lifecycle events and is optional.
See [system-events.md](system-events.md) for the full list.

### (12) Post-pair stream

After the burst, the watch transmits a continuous stream of asynchronous
requests. Compass handles them in `handleUnsolicited`
(`GarminDeviceManager.swift:200-307`). The minimum requirement for every
non-RESPONSE message is an ACK; several types need **extended** ACK
payloads or the watch retransmits every ~1 s. See
[message-format.md](message-format.md#known-extended-status-payloads).

## Avoiding the Send-and-Wait Race

`GFDIClient.sendAndWait` registers the response continuation **before**
the outbound write completes:

```swift
// GFDIClient.swift:138-148
public func sendAndWait(_ message: GFDIMessage, awaitType: GFDIMessageType, ...) async throws -> GFDIMessage {
    return try await awaitResponse(forType: awaitType.rawValue, timeout: timeout) {
        try await self.transport.sendGFDI(message.encode())
    }
}
```

`awaitResponse` inserts the continuation into `pendingContinuations` and
*then* runs the `beforeWait` closure (which performs the send). A
sub-millisecond reply cannot slip into the unsolicited handler.

## Compass-Specific Deviations Summary

| Behaviour                                        | Compass                                  | Gadgetbridge / docs            |
| ------------------------------------------------ | ---------------------------------------- | ------------------------------ |
| DEVICE_INFORMATION reply                         | Bare 9-byte ACK                          | Bare 9-byte ACK (matches)      |
| AUTH_NEGOTIATION                                 | Async via `handleUnsolicited`            | Awaited synchronously          |
| `TIME_UPDATED` SYSTEM_EVENT                      | **Skipped**                              | Sent if `syncTime` pref on     |
| Capability bitmask                               | All-1s (15 × `0xFF`)                     | Curated bitmask                |
| Compact type encoding                            | Decoded; never emitted                   | Decoded; emitted by firmware   |

The deadlock fix in commit `e8292f9` (releaseSendLock + protobuf/music
ACKs) is what made the post-init burst land reliably without the watch
disconnecting mid-burst.

## Source

- Compass: `Packages/CompassBLE/Sources/CompassBLE/Public/GarminDeviceManager.swift`,
  `GFDI/GFDIClient.swift`,
  `GFDI/Messages/{DeviceInformation,Configuration,AuthNegotiation,PostInit,SystemEvent,Response}.swift`.
- `docs/garmin/references/gadgetbridge-pairing.md` §§ 5, 7, 10–13.
- Tests: `Packages/CompassBLE/Tests/CompassBLETests/GFDIMessageTests.swift`.

## See Also

- [message-format.md](message-format.md)
- [message-types.md](message-types.md)
- [system-events.md](system-events.md)

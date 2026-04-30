# GFDI SYSTEM_EVENT (5030 / 0x13A6)

`SYSTEM_EVENT` is the bidirectional lifecycle channel: the host uses it to
walk the watch through pair-complete / sync-complete / setup-wizard-done,
and the watch may also send foreground/background notifications. The
payload is a fixed 2 bytes:

```
[eventType:  UInt8]
[eventValue: UInt8]   // 0 for unparameterised events
```

Total wire frame is therefore 8 bytes:
`length(2) + type=0x13A6(2) + eventType(1) + eventValue(1) + crc(2)`.

Compass: `Packages/CompassBLE/Sources/CompassBLE/GFDI/Messages/SystemEvent.swift`
(`SystemEventMessage.toMessage`).
Reference: Gadgetbridge `SystemEventMessage.java`,
`docs/garmin/references/gadgetbridge-pairing.md` § 13.

## Event Codes

Source of truth: `SystemEvent.swift:16-34`. **Direction** is from
Compass's perspective — *Out* = phone → watch, *In* = watch → phone.

| Code | Swift symbol             | Direction | When sent                                                                                                              |
| ---: | ------------------------ | --------- | ---------------------------------------------------------------------------------------------------------------------- |
|    0 | `.syncComplete`          | Out       | Final lifecycle marker after a sync session completes (or during the post-pair burst — see below).                     |
|    1 | `.syncFail`              | Out       | A sync session aborted abnormally. **Not currently emitted by Compass**; reserved for future error paths.              |
|    2 | `.factoryReset`          | Out       | Phone signals a factory-reset operation. **Not used by Compass.**                                                      |
|    3 | `.pairStart`             | Out       | First-time-pair start. **Not currently used by Compass** — `PAIR_COMPLETE` alone is enough for the Instinct Solar 1G.  |
|    4 | `.pairComplete`          | Out       | Pairing finished successfully. Sent during the post-init burst.                                                        |
|    5 | `.pairFail`              | Out       | Pairing aborted. **Not currently emitted by Compass** (it throws and tears down the link instead).                     |
|    6 | `.hostDidEnterForeground`| Out       | Companion app moved to foreground. **Not currently used by Compass.**                                                  |
|    7 | `.hostDidEnterBackground`| Out       | Companion app moved to background. **Not currently used by Compass.**                                                  |
|    8 | `.syncReady`             | Out       | Phone is ready to accept inbound file transfers. First lifecycle event in the post-init burst.                         |
|    9 | `.newDownloadAvailable`  | Out       | Companion has new firmware/data ready. **Not currently used by Compass.**                                              |
|   10 | `.deviceSoftwareUpdate`  | Out       | Companion has staged a software update. **Not currently used by Compass.**                                             |
|   11 | `.deviceDisconnect`      | Out       | Soft disconnect signal. Compass relies on the BLE/ML layer for disconnect today; this code is unused at runtime.       |
|   12 | `.tutorialComplete`      | Out       | User finished the on-watch tutorial. **Not currently used by Compass.**                                                |
|   13 | `.setupWizardStart`      | Out       | Begin the post-pair setup wizard. **Not currently used by Compass.**                                                   |
|   14 | `.setupWizardComplete`   | Out       | End the post-pair setup wizard. Last lifecycle event in the post-init burst.                                           |
|   15 | `.setupWizardSkipped`    | Out       | User opted out of the wizard. **Not currently used by Compass.**                                                       |
|   16 | `.timeUpdated`           | Out       | Phone pushed a new authoritative time. **Compass intentionally skips this** — see below.                               |

## Post-Init Burst Sequence

Inside `runHandshake` (`GarminDeviceManager.swift:484-494`) Compass emits
exactly four `SYSTEM_EVENT`s after the file-types probe and the device
settings, in this order:

```swift
try await gfdiClient.send(message: SupportedFileTypesRequestMessage().toMessage())  // 5031
try await gfdiClient.send(message: SetDeviceSettingsMessage.defaults().toMessage()) // 5026
try await gfdiClient.send(message: SystemEventMessage(eventType: .syncReady)        // 8
                                    .toMessage())
try await gfdiClient.send(message: SystemEventMessage(eventType: .pairComplete)     // 4
                                    .toMessage())
try await gfdiClient.send(message: SystemEventMessage(eventType: .syncComplete)     // 0
                                    .toMessage())
try await gfdiClient.send(message: SystemEventMessage(eventType: .setupWizardComplete) // 14
                                    .toMessage())
```

Order rationale:

1. **`SUPPORTED_FILE_TYPES_REQUEST` first.** Sending `SYNC_READY` before
   it caused the Instinct Solar 1G to disconnect cleanly. The watch
   gates lifecycle events on a prior file-types probe.
2. **`SYNC_READY` (8) → `PAIR_COMPLETE` (4) → `SYNC_COMPLETE` (0) →
   `SETUP_WIZARD_COMPLETE` (14).** Matches Gadgetbridge's
   `completeInitialization()` (see `gadgetbridge-pairing.md` § 13). The
   watch leaves its setup wizard once it receives `SETUP_WIZARD_COMPLETE`
   *and* a valid `CURRENT_TIME_REQUEST` reply.

## TIME_UPDATED is Skipped

Gadgetbridge emits `TIME_UPDATED` (16) with a 4-byte Garmin-epoch
timestamp (`javaMillisToGarminTimestamp(...)`) when its `syncTime`
preference is enabled. Compass deliberately skips this — see the comment
block at `GarminDeviceManager.swift:480-483`. The Instinct Solar 1G gets
its time from the watch's reply to `CURRENT_TIME_REQUEST` (which the
watch sends asynchronously a few seconds after pairing; Compass replies
in `handleUnsolicited`, see `GarminDeviceManager.swift:399-429`).

If `TIME_UPDATED` is added later, note that its `eventValue` field is
**different** from the rest of the table: it carries a 4-byte
little-endian Garmin timestamp rather than a single byte. The current
`SystemEventMessage` struct only encodes the 1-byte form
(`SystemEvent.swift:44-49`) and would need to be extended.

## Inbound `SYSTEM_EVENT`s

The watch may emit `SYSTEM_EVENT`s of its own (e.g. button-driven
`HOST_DID_ENTER_*` flips on some devices). Compass routes any inbound
`SYSTEM_EVENT` through `handleUnsolicited`, which falls into the `default`
arm and replies with a bare ACK
(`GarminDeviceManager.swift:302-306`). No higher-level callback fires.
Adding behaviour for a specific inbound event means extending the switch
in `handleUnsolicited`.

## Encoding Summary

| Offset | Size | Field      | Notes                                                                                |
| -----: | ---: | ---------- | ------------------------------------------------------------------------------------ |
|      0 |    1 | eventType  | One of the codes in the table above.                                                 |
|      1 |    1 | eventValue | `0` for every event Compass currently emits. Reserved for future per-event payloads. |

Compass: `SystemEvent.swift:44-49`.

## See Also

- [message-format.md](message-format.md) — wire framing and CRC.
- [message-types.md](message-types.md) — full type-code table.
- [pairing.md](pairing.md) — sequence diagram showing where these events
  fit in the broader handshake.

## Source

- Compass:
  `Packages/CompassBLE/Sources/CompassBLE/GFDI/Messages/SystemEvent.swift`,
  `Public/GarminDeviceManager.swift:471-494, 200-307`.
- Gadgetbridge: `SystemEventMessage.java`.
- `docs/garmin/references/gadgetbridge-pairing.md` § 13.
- `docs/garmin/references/gadgetbridge-sync.md` § 1.1 (sync-lifecycle
  framing).

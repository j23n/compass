# GFDI Message Types

Every GFDI frame carries a 16-bit little-endian type word that identifies
the message's purpose. The values match the decimal codes in the
Gadgetbridge `GarminMessage` enum. Compass exposes the subset it currently
understands as `GFDIMessageType` in
`Packages/CompassBLE/Sources/CompassBLE/GFDI/MessageTypes.swift`.

## Type Code Table

`Direction` is from Compass's perspective. **In** = watch → phone, **Out** =
phone → watch, **Bidir** = either side may originate.

| Type (hex) | Type (dec) | Swift symbol                  | Direction | Brief purpose                                                       |
| ---------- | ---------: | ----------------------------- | --------- | ------------------------------------------------------------------- |
| 0x1388     |       5000 | `.response`                   | Bidir     | Generic ACK/NACK envelope. Wraps `originalType + status + extras`.  |
| 0x138A     |       5002 | `.downloadRequest`            | Out       | Begin a phone-initiated FIT pull from a watch directory.            |
| 0x138B     |       5003 | `.uploadRequest`              | Out       | Begin a phone→watch file upload (e.g. courses).                     |
| 0x138C     |       5004 | `.fileTransferData`           | Bidir     | A file-transfer chunk (download body or upload body).               |
| 0x138D     |       5005 | `.createFile`                 | Out       | Reserve a slot for an upload file before pushing data.              |
| 0x138F     |       5007 | `.directoryFilter`            | Out       | List entries in a directory (used by `listCourseFiles`).            |
| 0x1390     |       5008 | `.setFileFlag`                | Out       | Mark a watch file as read / pending-delete.                         |
| 0x1393     |       5011 | `.fitDefinition`              | Out       | FIT message definition (e.g. weather records).                      |
| 0x1394     |       5012 | `.fitData`                    | Out       | FIT data record matching the prior definition.                      |
| 0x1396     |       5014 | `.weatherRequest`             | In        | Watch asks for current conditions / forecast for a lat/lon.         |
| 0x13A0     |       5024 | `.deviceInformation`          | In        | Watch announces itself (first GFDI frame post-ML).                  |
| 0x13A2     |       5026 | `.deviceSettings`             | Out       | TLV setting bundle (auto-upload, weather toggles, time, …).         |
| 0x13A6     |       5030 | `.systemEvent`                | Bidir     | Lifecycle: pair start/complete, sync start/complete, etc.           |
| 0x13A7     |       5031 | `.supportedFileTypesRequest`  | Out       | Ask watch which file types it supports (empty payload).             |
| 0x13A9     |       5033 | `.notificationUpdate`         | Out       | Push notification add/replace.                                      |
| 0x13AA     |       5034 | `.notificationControl`        | In        | Watch-side dismiss / reply action on a notification.                |
| 0x13AB     |       5035 | `.notificationData`           | Out       | Long-text continuation chunks for notifications.                    |
| 0x13AC     |       5036 | `.notificationSubscription`   | In        | Watch declares which notification streams it wants.                 |
| 0x13AD     |       5037 | `.synchronization`            | In        | Watch-initiated "I have new files" trigger.                         |
| 0x13AF     |       5039 | `.findMyPhoneRequest`         | In        | "Ring my phone" started.                                            |
| 0x13B0     |       5040 | `.findMyPhoneCancel`          | In        | Cancel ring.                                                        |
| 0x13B1     |       5041 | `.musicControl`               | In        | Watch sends a music command ordinal (play/pause/skip/…).            |
| 0x13B2     |       5042 | `.musicControlCapabilities`   | In        | Watch asks which music commands the host advertises.                |
| 0x13B3     |       5043 | `.protobufRequest`            | In        | Wraps a protobuf message; reply is RESPONSE with status block.      |
| 0x13B4     |       5044 | `.protobufResponse`           | Bidir     | Protobuf reply frame (used for richer data, e.g. settings).         |
| 0x13B9     |       5049 | `.musicControlEntityUpdate`   | Out       | Push current track / artist / playback state to the watch.          |
| 0x13BA     |       5050 | `.configuration`              | Bidir     | Capability bitmask exchange.                                        |
| 0x13BC     |       5052 | `.currentTimeRequest`         | In        | Watch asks for current Garmin-epoch time + DST metadata.            |
| 0x13ED     |       5101 | `.authNegotiation`            | In        | Optional auth handshake; host answers with a GUESS_OK echo.         |

Compass: `MessageTypes.swift:9-43`.

## Compact Form (`& 0x8000`)

The Garmin firmware can save two bytes per frame by setting the high bit of
the type word. When `rawType & 0x8000 != 0`, the actual decimal type is
`(rawType & 0x00FF) + 5000`. This only covers the 5000–5255 range, which
happens to include the entire table above.

Compass folds this back during decode and **never emits the compact form**
on egress:

```swift
// GFDIMessage.swift:106-111
var rawType = UInt16(data[start + 2]) | (UInt16(data[start + 3]) << 8)
if rawType & 0x8000 != 0 {
    rawType = (rawType & 0x00FF) &+ 5000
}
```

Reference: Gadgetbridge `GFDIMessage.java#parseIncoming`. The watch sends
the compact form opportunistically; Compass decodes both. Outgoing frames
always use the full 16-bit decimal type to keep wire dumps readable.

## Routing in GFDIClient

When a frame arrives, `GFDIClient.routeMessage` (Compass:
`GFDIClient.swift:79-93`) looks up its type in this priority order:

1. **Subscriptions** — persistent streams (e.g. file-transfer chunk loops).
2. **Pending one-shot continuations** — registered by `waitForMessage` or
   `sendAndWait`. Yielded once and removed.
3. **Unsolicited handler** — `handleUnsolicited` in
   `GarminDeviceManager.swift:200-307`, which must ACK every non-RESPONSE
   message or the watch retransmits every ~1 s.

`sendAndWait` registers the response continuation **before** writing to the
wire (`GFDIClient.swift:138-148`) so that a very-fast reply cannot slip
into the unsolicited handler in the gap between send and wait.

## Compass-Specific Notes

- Several types in the Gadgetbridge enum are **not** present in
  `GFDIMessageType` because Compass has no path that produces or consumes
  them yet. Adding one is straightforward: extend `MessageTypes.swift`,
  add a payload struct under `GFDI/Messages/`, and (if it arrives
  unsolicited) extend the switch in `handleUnsolicited`.
- Unknown type codes throw `DecodeError.unknownType` rather than being
  silently swallowed (`GFDIMessage.swift:136-138`). This makes new traffic
  patterns visible during development.
- Several types require **extended** RESPONSE payloads, not bare ACKs. See
  [message-format.md](message-format.md#known-extended-status-payloads).

## See Also

- [message-format.md](message-format.md) — frame layout and CRC.
- [pairing.md](pairing.md) — order in which these types appear.
- [system-events.md](system-events.md) — `SYSTEM_EVENT` (5030) sub-types.

## Source

- Compass: `Packages/CompassBLE/Sources/CompassBLE/GFDI/MessageTypes.swift`,
  `GFDIClient.swift`, `Public/GarminDeviceManager.swift`.
- Gadgetbridge: `GarminMessage.java` (decimal-code source of truth).
- `docs/garmin/references/gadgetbridge-pairing.md` § 7.

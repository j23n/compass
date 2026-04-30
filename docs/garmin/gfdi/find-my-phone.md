# Find My Phone

The watch's "Find My Phone" workflow is a pair of zero-payload triggers:

| Type | ID   | Hex     | Direction      | Meaning                  |
|------|------|---------|----------------|--------------------------|
| 5039 | 5039 | 0x13AF  | watch → phone  | `FIND_MY_PHONE_REQUEST`  |
| 5040 | 5040 | 0x13B0  | watch → phone  | `FIND_MY_PHONE_CANCEL`   |

Both messages carry no payload bytes. The phone replies with a bare
`RESPONSE` (5000) ACK and dispatches a Compass-side event.

See also: [`./message-format.md`](./message-format.md), [`./message-types.md`](./message-types.md).

## Wire format

Each message is just the GFDI envelope and message type — no payload:

```
[length: UInt16 LE]
[type:   UInt16 LE = 0x13AF or 0x13B0]
[crc:    UInt16 LE]
```

Compass replies with `GFDIResponse(originalType: …, status: .ack)` — also a
zero-extra-bytes RESPONSE message. The same shape used for any non-extended
ACK on the protocol.

## Handler dispatch

`GarminDeviceManager` ACKs immediately and posts a typed event into the host
app (`GarminDeviceManager.swift:266-276`):

```swift
case .findMyPhoneRequest:
    BLELogger.gfdi.info("FIND_MY_PHONE_REQUEST")
    let ack = GFDIResponse(originalType: .findMyPhoneRequest, status: .ack)
    try? await client.send(message: ack.toMessage())
    findMyPhoneHandler?(.started)

case .findMyPhoneCancel:
    BLELogger.gfdi.info("FIND_MY_PHONE_CANCEL")
    let ack = GFDIResponse(originalType: .findMyPhoneCancel, status: .ack)
    try? await client.send(message: ack.toMessage())
    findMyPhoneHandler?(.cancelled)
```

The event type is defined at `DeviceServiceCallbacks.swift:42-46`:

```swift
public enum FindMyPhoneEvent: Sendable {
    case started
    case cancelled
}
```

The handler closure is registered via `setFindMyPhoneHandler(_:)`
(`GarminDeviceManager.swift:74-76`).

## Compass response: `FindMyPhoneService`

`Compass/Services/FindMyPhoneService.swift` reacts to the event in two ways:
an audible tone and a notification banner.

### Idempotence

`isRinging` ensures repeated `FIND_MY_PHONE_REQUEST` messages don't spawn
multiple audio engines, and `FIND_MY_PHONE_CANCEL` is a no-op when nothing is
ringing (`FindMyPhoneService.swift:22-34`).

### Audio session

```swift
try? session.setCategory(.playback, mode: .default, options: [.duckOthers])
try? session.setActive(true)
```

`FindMyPhoneService.swift:54-59`. `.playback` plays through the silent switch.
`.duckOthers` lowers any other audio (Spotify, podcasts) while the tone
plays — important since the user is by definition unable to find the phone
to silence other apps manually.

### Tone synthesis

A single 0.6 s sine-wave buffer is generated at runtime — no bundled audio
file (`FindMyPhoneService.swift:61-111`).

| Property      | Value                                       |
|---------------|---------------------------------------------|
| Frequency     | 880 Hz (A5)                                 |
| Sample rate   | 44 100 Hz                                   |
| Duration      | 0.6 s per buffer                            |
| Amplitude     | 0.85 with a 50 ms linear fade-out at end    |
| Format        | mono float32 (`standardFormatWithSampleRate`) |
| Looping       | `AVAudioPlayerNode.scheduleBuffer` with `.loops` |

The fade-out hides the buffer-loop seam so the repeat sounds like a steady
beat rather than a glitch. Looping continues until `stopTone()` is called
from `cancelled` handling.

### Notification banner

`FindMyPhoneService.swift:113-138`. Posts a `UNNotificationRequest` with:

| Field     | Value                                                |
|-----------|------------------------------------------------------|
| Identifier| `"com.compass.findmyphone"` (single live banner)     |
| Title     | `"Find My Phone"`                                    |
| Body      | `"Your Garmin watch is looking for your phone."`     |
| Sound     | `.default` (in addition to the AVAudio tone)         |
| Trigger   | `nil` — fire immediately                             |

Authorization status is checked first; the banner is skipped if neither
`.authorized` nor `.provisional` is granted.

On cancel, `removeDeliveredNotifications` and
`removePendingNotificationRequests` clear that single identifier
(`FindMyPhoneService.swift:47-51`) so the user can never end up with stale
banners from previous triggers.

## Lifecycle summary

```
watch ──FIND_MY_PHONE_REQUEST──▶ phone
phone ──RESPONSE ACK─────────────▶ watch
phone:  start audio session
phone:  AVAudioEngine starts looping 880 Hz tone
phone:  post UNUserNotification banner
…
watch ──FIND_MY_PHONE_CANCEL───▶ phone
phone ──RESPONSE ACK─────────────▶ watch
phone:  stop player node, stop engine
phone:  deactivate audio session (notifyOthersOnDeactivation)
phone:  remove delivered + pending notifications
```

## Edge cases

- **Notifications not permitted** — tone still plays; only the banner is
  skipped (`FindMyPhoneService.swift:117-121`).
- **Audio session activation failure** — silently swallowed (`try?`); the
  tone may not be audible but the banner still posts.
- **Watch dies mid-ring** — without a CANCEL, ringing continues until the
  user dismisses the notification or kills the app. There is no timeout.
  Gadgetbridge has the same behavior.

## References

- Compass: `Compass/Services/FindMyPhoneService.swift`
- Compass: `Packages/CompassBLE/Sources/CompassBLE/Public/GarminDeviceManager.swift:266-276, 74-76`
- Compass: `Packages/CompassBLE/Sources/CompassBLE/Public/DeviceServiceCallbacks.swift:42-46`
- Compass: `Packages/CompassBLE/Sources/CompassBLE/GFDI/MessageTypes.swift:33-34`
- Gadgetbridge: `FindMyPhoneRequestMessage.java`,
  `FindMyPhoneCancelMessage.java`

Source: [`FindMyPhoneService.swift`](../../../Compass/Services/FindMyPhoneService.swift),
[`GarminDeviceManager.swift`](../../../Packages/CompassBLE/Sources/CompassBLE/Public/GarminDeviceManager.swift),
[`DeviceServiceCallbacks.swift`](../../../Packages/CompassBLE/Sources/CompassBLE/Public/DeviceServiceCallbacks.swift).

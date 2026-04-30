# Music control

Three GFDI message types make up the watch's music remote:

| Type | ID   | Hex     | Direction      | Purpose                                    |
|------|------|---------|----------------|--------------------------------------------|
| 5041 | 5041 | 0x13B1  | watch → phone  | `MUSIC_CONTROL` command (one ordinal byte) |
| 5042 | 5042 | 0x13B2  | watch → phone  | `MUSIC_CONTROL_CAPABILITIES` probe         |
| 5049 | 5049 | 0x13B9  | phone → watch  | `MUSIC_CONTROL_ENTITY_UPDATE` push (TLV)   |

The watch retransmits each message ~1 s until ACKed, so every inbound type
must be answered, even if there is nothing useful to do.

See also: [`./message-format.md`](./message-format.md), [`./message-types.md`](./message-types.md).

## 5041 — `MUSIC_CONTROL` commands

Each `MUSIC_CONTROL` message carries a single command ordinal in
`payload[0]`. Defined in `MusicControl.swift:6-14`:

| Ordinal | Case                  | Action in Compass                              |
|---------|-----------------------|------------------------------------------------|
| 0       | `playPause`           | toggle `MPMusicPlayerController` play/pause    |
| 1       | `skipToNextCuepoint`  | maps to `skipToNextItem()`                     |
| 2       | `skipBackToCuepoint`  | maps to `skipToPreviousItem()`                 |
| 3       | `nextTrack`           | `skipToNextItem()`                             |
| 4       | `previousTrack`       | `skipToPreviousItem()`                         |
| 5       | `volumeUp`            | logged and ignored — no sandbox API            |
| 6       | `volumeDown`          | logged and ignored — no sandbox API            |

Per-command ACK pattern (commit `e8292f9`): a bare `RESPONSE` ACK with no
extra bytes. Sent before dispatch so retransmission stops immediately:

```swift
case .musicControl:
    let ack = GFDIResponse(originalType: .musicControl, status: .ack)
    try? await client.send(message: ack.toMessage())
    if msg.payload.count >= 1 {
        let ordinal = msg.payload[0]
        BLELogger.gfdi.info("MUSIC_CONTROL command=\(ordinal)")
        musicCommandHandler?(ordinal)
    }
```

Compass: `GarminDeviceManager.swift:254-261`.

The ordinal is dispatched into `MusicService.handleCommand(ordinal:)`
(`MusicService.swift:41-63`), which routes to
`MPMusicPlayerController.systemMusicPlayer`. iOS sandbox restrictions mean:

- The system music player only controls Apple Music. Spotify and other
  third-party players cannot be remote-controlled from a non-extension app.
- System volume cannot be set programmatically. Volume buttons on a Bluetooth
  headset (or the watch's own volume keys when paired directly to a headset)
  take precedence anyway.

## 5042 — capabilities probe

Right after pairing the watch sends `MUSIC_CONTROL_CAPABILITIES` to ask which
ordinals the phone supports. Compass replies with a `RESPONSE` ACK that
echoes the supported ordinal list (`GarminDeviceManager.swift:241-252`):

```
[originalType: UInt16 LE = 0x13B2]
[status:       UInt8     = 0x00 (ACK)]
[count:        UInt8]                  ← number of ordinals that follow
[ordinals:     count × UInt8]
```

```swift
case .musicControlCapabilities:
    let commands = GarminMusicControlCommand.allCases.map(\.rawValue)
    var extra = Data()
    extra.append(UInt8(commands.count))
    extra.append(contentsOf: commands)
    let capsAck = GFDIResponse(
        originalType: .musicControlCapabilities,
        status: .ack,
        additionalPayload: extra
    )
    try? await client.send(message: capsAck.toMessage())
```

Compass advertises all seven ordinals (0…6) regardless of which ones it can
actually execute. The volume commands are advertised so the watch's UI shows
the volume controls; iOS silently drops them.

## 5049 — `MUSIC_CONTROL_ENTITY_UPDATE` push

Outgoing message that updates the watch's now-playing screen. The payload is
a sequence of TLV tuples:

```
[entity:    UInt8]
[attribute: UInt8]
[flags:     UInt8]
[length:    UInt16 LE]
[value:     length bytes]
```

Compass: `MusicControl.swift:86-98`.

### Entity / attribute table

`MusicControl.swift:18-23` & `:39-72`.

| Entity | Attr | Type / encoding              | Meaning                                      |
|-------:|-----:|------------------------------|----------------------------------------------|
| 0      | 0    | UTF-8                        | Player name (Compass sends `"Music"`)        |
| 0      | 1    | UInt8                        | Playback state — 0=paused, 1=playing, 3=stopped |
| 0      | 2    | UInt8                        | Volume 0–100 (not pushed by Compass)         |
| 1      | 0    | bytes                        | Operations supported (queue, not used here)  |
| 1      | 1    | bytes                        | Shuffle state (not used here)                |
| 1      | 2    | bytes                        | Repeat state (not used here)                 |
| 2      | 0    | UTF-8                        | Track artist                                 |
| 2      | 1    | UTF-8                        | Track album                                  |
| 2      | 2    | UTF-8                        | Track title                                  |
| 2      | 3    | UInt32 LE (ms)               | Track duration                               |

The `flags` byte is always 0 in Compass — Gadgetbridge defines it but Compass
has no need for the flag bits.

## Bridge to `MPNowPlayingInfoCenter`

`MusicService` registers for two notifications and re-pushes the current
state on each (`MusicService.swift:67-80`):

- `MPMusicPlayerControllerNowPlayingItemDidChange`
- `MPMusicPlayerControllerPlaybackStateDidChange`

Each push (`MusicService.swift:84-110`) gathers:

1. Player entity fixed to `"Music"` plus the current playback state.
2. Track entity built from `MPNowPlayingInfoCenter.default().nowPlayingInfo`,
   skipping any field that is empty/zero. This keeps the watch from
   over-writing a previously good value with an empty string when iOS clears
   `nowPlayingInfo` between tracks.

Empty-field skipping applies to `title`, `artist`, `album`, and `duration`.

`startObserving` calls `beginGeneratingPlaybackNotifications()` and
immediately invokes `pushCurrentState()` so the watch's now-playing UI is
populated as soon as the connection comes up
(`MusicService.swift:25-30`).

## ACK summary

| Inbound type                   | Reply                                        |
|--------------------------------|----------------------------------------------|
| 5041 MUSIC_CONTROL             | RESPONSE ACK (no extra bytes)                |
| 5042 MUSIC_CONTROL_CAPABILITIES| RESPONSE ACK + `[count][ordinals…]`          |

5049 is outgoing. Compass does not look for an ACK from the watch.

## References

- Compass: `Packages/CompassBLE/Sources/CompassBLE/GFDI/Messages/MusicControl.swift`
- Compass: `Compass/Services/MusicService.swift`
- Compass: `Packages/CompassBLE/Sources/CompassBLE/Public/GarminDeviceManager.swift:241-261`
- Gadgetbridge: `GarminMusicControlCommand.java`,
  `MusicControlEntityUpdateMessage.java`,
  `MusicControlCapabilitiesMessage.java`
- Commit `e8292f9` — per-command ACK pattern

Source: [`MusicControl.swift`](../../../Packages/CompassBLE/Sources/CompassBLE/GFDI/Messages/MusicControl.swift),
[`MusicService.swift`](../../../Compass/Services/MusicService.swift),
[`GarminDeviceManager.swift`](../../../Packages/CompassBLE/Sources/CompassBLE/Public/GarminDeviceManager.swift).

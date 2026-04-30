# Garmin CRC-16

A 16-bit nibble-table CRC used by every GFDI message and by Garmin's
FIT / ANT-FS file formats. **This is NOT CRC-16/CCITT.** Mixing the two
silently corrupts every message; the watch will discard the frame
without any error indication, and the symptom from the host side is "no
response and no ACK".

Implementation: `Compass: CRC16.swift` (31 lines).
Reference: `Gadgetbridge: ChecksumCalculator.java:21-49`.

---

## Algorithm

Two nibble passes per input byte through a 16-entry constant table:

```swift
// Compass: CRC16.swift:23-30
public static func compute(data: Data, seed: UInt16 = 0) -> UInt16 {
    var crc = seed
    for byte in data {
        crc = ((crc >> 4) & 0x0FFF) ^ constants[Int(crc & 0x0F)]
                                    ^ constants[Int(byte & 0x0F)]
        crc = ((crc >> 4) & 0x0FFF) ^ constants[Int(crc & 0x0F)]
                                    ^ constants[Int((byte >> 4) & 0x0F)]
    }
    return crc
}
```

| Property                    | Value                          |
|-----------------------------|--------------------------------|
| Polynomial (reversed)       | `0x8408` (= reversed CRC-16-IBM)|
| Initial value (default seed)| `0x0000`                       |
| Final XOR                   | none                           |
| Bit order                   | low nibble first, then high    |
| Output                      | `UInt16`, stored LE on the wire|
| Table size                  | 16 entries × `UInt16`          |

The `& 0x0FFF` mask after `>> 4` is intentional — it discards the top
4 bits before the XOR so the algorithm matches the FIT SDK byte-for-byte.

---

## Constants table

`Compass: CRC16.swift:12-15`:

```
0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400
```

These are the byte-pair lookups for the polynomial `0x8408` (reversed
CRC-16-IBM, also known as the FIT/ANT-FS CRC). Identical table at
`Gadgetbridge: ChecksumCalculator.java:21-25`.

---

## Seed / running CRC

The `seed` parameter (`Compass: CRC16.swift:23`) supports running CRCs
across chunked file transfers. Garmin's file-transfer protocol verifies
each chunk against the **cumulative** CRC of all bytes received so far,
not just the bytes in the chunk:

```swift
var running: UInt16 = 0
for chunk in fileChunks {
    running = CRC16.compute(data: chunk, seed: running)
    // compare `running` against the watch's reported running CRC
}
```

For one-shot use (a complete GFDI message, a single FIT record, etc.)
pass `seed = 0` (the default).

---

## Use in GFDI

The CRC is the trailing 2 bytes of every GFDI message, computed over
`[length(2) | type(2) | payload(N)]` and stored as little-endian:

| Offset       | Size | Field    |
|--------------|------|----------|
| 0            | 2    | length (LE)  — total message length **including** CRC |
| 2            | 2    | type   (LE)                                          |
| 4            | N    | payload                                              |
| 4+N          | 2    | crc16  (LE) — over bytes `[0, 4+N)`                  |

The `length` field includes itself, the type, the payload, and the
CRC bytes. CRC scope deliberately excludes only the CRC bytes themselves
(which haven't been written yet at the time of computation).

Reference: `Gadgetbridge: GFDIMessage.java:87-90, 164-196`.

---

## Why this is NOT CRC-16/CCITT

CRC-16/CCITT (sometimes called "CRC-16 XMODEM" or "CRC-16/X.25") uses
polynomial `0x1021` with initial value `0xFFFF` and various final XOR
values. Plugging a CCITT implementation into the Garmin transport
produces a CRC the watch silently rejects.

Quick distinguishing tests:

| Input     | Garmin CRC-16 | CRC-16/CCITT (init 0xFFFF) |
|-----------|---------------|----------------------------|
| `[]`      | `0x0000`      | `0xFFFF`                   |
| `[0x00]`  | `0x0000`      | `0x1EF0`                   |

(Garmin: `Compass: CRC16Tests.swift:9-19` — explicit `0x0000` for both
empty and single-zero input.)

If your CRC for an empty `Data` is anything other than `0x0000`, you're
running the wrong algorithm.

---

## Test vectors

`Compass: CRC16Tests.swift`:

| Test                                 | Input                                    | Expected |
|--------------------------------------|------------------------------------------|----------|
| `emptyData`                          | `Data()`                                 | `0x0000` |
| `singleByteZero`                     | `Data([0x00])`                           | `0x0000` |
| `realWireBytes` (Instinct Solar DI)  | 48-byte captured DEVICE_INFORMATION body | `0xAD67` |

The `realWireBytes` vector at `Compass: CRC16Tests.swift:21-34` is the
authoritative regression test — those bytes were captured directly from
the watch's outbound notification stream during a successful pairing,
and `0xAD67` is the CRC the watch itself appended.

A useful additional spot-check from the Gadgetbridge reference: the
ASCII bytes `"OK"` (`0x4F 0x4B`) produce `0x71C2` under this algorithm
(see `docs/garmin/references/gadgetbridge-pairing.md` §6).

---

## Failure modes when wrong

If you ship the wrong algorithm, you will see:

1. The watch never ACKs your messages (CRC fails its `checkCRC()` call —
   `Gadgetbridge: GFDIMessage.java:172`).
2. The watch may NAK with `Status.CRC_ERROR` (ordinal `4`) inside a
   `RESPONSE (5000)` frame. Some firmware just drops the message
   silently.
3. Your code, in turn, fails to validate the watch's outbound messages
   and complains about CRC mismatch on every inbound frame.

Either symptom is unambiguous: change the algorithm to the nibble-table
form above.

---

## Source

* `Compass: Packages/CompassBLE/Sources/CompassBLE/Utils/CRC16.swift`
* `Compass: Packages/CompassBLE/Tests/CompassBLETests/CRC16Tests.swift`
* `Gadgetbridge: service/devices/garmin/ChecksumCalculator.java:21-49`
* `Gadgetbridge: service/devices/garmin/messages/GFDIMessage.java:87-196`
* `docs/garmin/references/gadgetbridge-pairing.md` §5, §6

Cross-references: [gatt.md](gatt.md), [multi-link.md](multi-link.md),
[cobs.md](cobs.md).

# Garmin-Variant COBS

COBS (Consistent Overhead Byte Stuffing) is the byte-stuffing layer that
sits between [Multi-Link](multi-link.md) and the GFDI message framer. It
guarantees that no `0x00` byte ever appears inside an encoded GFDI body
so that `0x00` can be used unambiguously as a frame delimiter on the
wire.

Implementation: `Compass: CobsCodec.swift` (175 lines).
Reference: `Gadgetbridge: CobsCoDec.java`.

---

## Why a Garmin-specific variant

Standard COBS prepends a code byte and uses a single trailing `0x00` as
the frame terminator. **Garmin's variant adds a leading `0x00` as well**:

```
0x00 [code, data...] [code, data...] ... 0x00
```

Both delimiters are required. The decoder treats the **first** `0x00`
after the leading delimiter as the trailing terminator (the COBS body
itself can never contain a zero by construction). Using
`lastIndex(of: 0)` instead is wrong — when several GFDI messages arrive
back-to-back the buffer holds `[00 body1 00 00 body2 00 …]` and last-
index picks the wrong terminator, merging two messages into one
corrupted blob (`Compass: CobsCodec.swift:128-139`).

---

## Encoding

`Compass: CobsCodec.swift:20-62` — `CobsCodec.encode(_:)`:

| Step | Action                                                              |
|------|---------------------------------------------------------------------|
| 1    | Emit leading `0x00`                                                 |
| 2    | Walk input; for each non-zero run of length `n` (up to `0xFE`):     |
|      |   emit code `n + 1` followed by the run bytes                       |
| 3    | If `n >= 0xFE`, emit a `0xFF` block of exactly 254 bytes (no implicit zero), then continue |
| 4    | If the input ended exactly on a `0x00`, emit a trailing `0x01` (zero-length pseudo-run) |
| 5    | Emit trailing `0x00`                                                |

Each block-code byte is `payloadSize + 1` (range `0x01..0xFE`); the
sentinel `0xFF` means "254 non-zero bytes follow and **no** implicit
`0x00` between this block and the next" (used for pure long runs).

Block code semantics on decode:

| Code            | Meaning                                                    |
|-----------------|------------------------------------------------------------|
| `0x01`          | Empty run; emit a `0x00` (unless this is the last block)   |
| `0x02..0xFE`    | Emit `code-1` literal bytes, then a `0x00` (unless last)   |
| `0xFF`          | Emit 254 literal bytes, **no** trailing implicit `0x00`    |

The "last block" qualifier is what suppresses the spurious zero at the
end of the message — without it, every encoded message would gain a
phantom `0x00` byte after decoding.

### Worst-case overhead

A buffer of all-zero bytes encodes to 1 byte of overhead per data byte
(every `0x00` becomes a fresh `0x01` block). A buffer with no zeros
gains exactly one code byte per 254 data bytes (~0.4%). Compass
allocates `data.count * 2 + 2` capacity (`Compass: CobsCodec.swift:21`)
to cover the worst case.

---

## Decoding (stateful)

`Compass: CobsCodec.swift:66-174` — `CobsCodec.Decoder`. The decoder is
stateful because the BLE layer chunks COBS frames across multiple
notifications; bytes accumulate in `buffer` until the trailing `0x00`
arrives, at which point one or more complete decoded messages move into
`pending`.

### Buffering rules

`receivedBytes(_:)` (`Compass: CobsCodec.swift:77-100`):

1. Append the new bytes to `buffer`.
2. Try to decode if a complete frame is now present.
3. **Interleave-start guard** (the bug fix below).

`retrieveMessage()` (`Compass: CobsCodec.swift:103-109`) yields one
decoded message at a time and re-runs `decodeIfReady` to peel off the
next.

### `decodeIfReady` algorithm

`Compass: CobsCodec.swift:113-173`:

1. Strip any junk before the first `0x00` (`firstIndex(of: 0)`).
2. Find the next `0x00` after the leading one, scanning forward — this
   is the trailing terminator.
3. Slice `body = buffer[1..<terminatorIndex]`.
4. Walk `body`: read `code`, copy `code-1` bytes into `out`, append a
   synthetic `0x00` between blocks unless `code == 0xFF` or this is the
   last block.
5. Stash result in `pending`; remove consumed bytes from `buffer`.
6. If `pending` was just consumed, re-enter the loop to surface the
   next pipelined message.

Malformed input (block claims more bytes than remain in `body`) drops
the entire frame silently (`Compass: CobsCodec.swift:158-162`).

---

## The interleave-start fix (commit `e756105`)

`Compass: CobsCodec.swift:95-97`:

```swift
if data.first == 0x00 && data.count > 1 && !buffer.isEmpty {
    buffer.removeAll(keepingCapacity: true)
}
```

A notification whose first byte is `0x00` has two distinct meanings on
the BLE wire:

1. **NEW MESSAGE START.** The watch began a fresh independent GFDI
   message while we were still accumulating the previous one's
   fragments. The notification carries the COBS leading byte plus the
   start of the new body, so `data.count > 1`. The accumulated buffer
   from the previous (incomplete) message is now junk; the watch will
   retransmit anything we lose. Drop it.
2. **TRAILING TERMINATOR.** The COBS body of a multi-fragment message
   filled the previous notification exactly; the final `0x00` arrives
   alone in the next notification. `data.count == 1`. Appending to the
   buffer lets `decodeIfReady` complete the pending message.

The previous bug used `data.first == 0x00` without the `count > 1`
check (or the `!buffer.isEmpty` check), which discarded valid
accumulated buffers whenever the trailing terminator arrived as a lone
byte. Symptom: the watch retransmitted the affected message every ~5
seconds with no progress, and the host hung indefinitely waiting for an
ACK that depended on a successfully decoded inbound message.

The full rationale is documented inline at `Compass:
CobsCodec.swift:78-94`.

---

## Layering with Multi-Link

Outbound (Compass → watch) — `Compass: MultiLinkTransport.swift:120-151`:

```
gfdi_message  →  CobsCodec.encode  →  [00 ... body ... 00]
              →  split into chunks of (maxWriteSize - 1)
              →  for each chunk: prepend [handle], BLE write
```

Only the first fragment carries the leading `0x00`; only the last
carries the trailing `0x00`.

Inbound (watch → Compass) — `Compass: MultiLinkTransport.swift:217-234`:

```
notification[0]      →  handle (dropped if 0x00 = management)
notification[1...]   →  decoder.receivedBytes(...)
                     →  decoder.retrieveMessage() repeatedly
                     →  yield decoded GFDI bytes upstream
```

`decoder.reset()` is called in `initializeGFDI` (`Compass:
MultiLinkTransport.swift:110`) and `shutdown()` (`:192`) so a stale
partial buffer from a previous BLE session can never poison the first
message of the next.

---

## Source

* `Compass: Packages/CompassBLE/Sources/CompassBLE/Transport/CobsCodec.swift`
* `Compass: Packages/CompassBLE/Sources/CompassBLE/Transport/MultiLinkTransport.swift:217-234`
* `Gadgetbridge: service/devices/garmin/communicator/CobsCoDec.java:44-124`
* `docs/garmin/references/gadgetbridge-pairing.md` §4

Cross-references: [gatt.md](gatt.md), [multi-link.md](multi-link.md),
[crc16.md](crc16.md).

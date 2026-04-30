# FIT Compressed Timestamps (§3.3.7)

_Source-derived from `Packages/CompassFIT/Sources/CompassFIT/Parsers/FITDecoder.swift`
lines 165-194. Reference: Garmin FIT Protocol §3.3.7._

The FIT format defines two ways for a data record to carry a timestamp:

1. **Explicit field 253** — the message definition lists field number 253 as a `uint32`
   (base type `0x86`) holding the absolute Garmin-epoch timestamp. Costs 4 bytes per record
   plus a 3-byte field-def line in each definition.
2. **Compressed timestamp** — the record header byte itself carries a 5-bit time delta
   from a rolling baseline. Costs zero extra bytes per record (the timestamp lives inside
   the record-header byte that you'd write anyway).

Compressed timestamps are optional and per-record — the same local message type can be
defined without field 253 and emit some records with compressed-timestamp headers and
others (the ones at "wraparound" boundaries) with regular headers, as long as the writer
is careful. Compass does not emit compressed timestamps, but its decoder handles them
correctly when they appear in files synced from Garmin watches.

---

## 1. The record header byte

For a *normal* record header (data or definition), bit 7 is 0 and the lower nibble is the
local message type (0–15). For a *compressed-timestamp* header, bit 7 is 1 and the byte is
re-interpreted:

```
  bit  7    = 1                  (compressed-timestamp flag)
  bits 6-5  = local_message_type (0–3, only 4 values addressable)
  bits 4-0  = time_offset        (0–31 seconds)
```

This is critically narrower than a normal header: only 4 local message types (0–3) can
participate in compressed-timestamp encoding. Definitions with local type 4–15 must use
explicit field 253 if they want timestamps.

`FITDecoder.swift:172-173`:

```swift
let localType  = (recordHeader >> 5) & 0x03
let timeOffset = UInt32(recordHeader & 0x1F)
```

---

## 2. The rolling baseline rule

The decoder keeps a single `lastTimestamp: UInt32` cursor for the entire file
(`FITDecoder.swift:163`). Every time a *non-compressed* data record carries field 253,
that absolute timestamp replaces `lastTimestamp` (`FITDecoder.swift:210-212`). Every time
a compressed-timestamp record is read, the 5-bit `time_offset` is combined with
`lastTimestamp` to reconstitute a full 32-bit timestamp:

```
maskedLast = lastTimestamp & 0x1F            (the previous bottom 5 bits)
if time_offset >= maskedLast:
    new_ts = (lastTimestamp & ~0x1F) | time_offset       (no rollover)
else:
    new_ts = ((lastTimestamp & ~0x1F) + 0x20) | time_offset   (rolled over)
lastTimestamp = new_ts
```

The rule says: **the 5-bit offset replaces the bottom 5 bits of the baseline**. If the new
offset is *smaller* than the previous offset, that means at least 32 seconds have elapsed
and the upper bits have to be incremented by one (i.e. the bottom 5 bits "rolled over").

This decode is at `FITDecoder.swift:181-188`:

```swift
let maskedLast = lastTimestamp & 0x1F
let newTimestamp: UInt32
if timeOffset >= maskedLast {
    newTimestamp = (lastTimestamp & ~UInt32(0x1F)) | timeOffset
} else {
    newTimestamp = ((lastTimestamp & ~UInt32(0x1F)) &+ 0x20) | timeOffset
}
lastTimestamp = newTimestamp
```

Note `&+ 0x20`: the wrapping add is intentional. If `lastTimestamp` is at the very top of
the uint32 range (years 2155-ish), the +32 would overflow; the spec defines the cursor as
modular, so wrapping is correct. In practice this never happens — Garmin watches have
plausible clocks.

### Worked example

Assume `lastTimestamp = 1_700_000_005` (ends in binary `…00101`, i.e. low 5 bits = 5).

| Compressed header | offset | maskedLast | branch | new_ts                 |
|-------------------|--------|------------|--------|------------------------|
| 0xA7 (`10100111`) | 7      | 5          | ≥      | 1_700_000_005 → 7      |
| 0xAB (`10101011`) | 11     | 7          | ≥      | …5 base + 11 = …11     |
| 0xA0 (`10100000`) | 0      | 11         | <      | wrap: …5 base + 32, +0 |

The "wrap" case advances the upper bits by 32 and zeroes the bottom 5 bits, so the
reconstructed timestamp jumps from "base+11" to "base+32".

### What this means for files Compass reads

Real Garmin watches mostly use compressed timestamps inside dense streams (e.g.
HSA-adjacent records, monitoring archives) where consecutive samples are <32 seconds
apart, with one anchor record per chunk that establishes a fresh baseline. The encoder
must guarantee that *some* non-compressed record carrying field 253 appears whenever the
gap exceeds 32 seconds — otherwise the rollover rule cannot recover the upper bits.

---

## 3. Field 253 injection

Once the decoder reconstructs the absolute timestamp, it would be awkward for downstream
parsers to need to know whether a given record came from a compressed header or an
explicit field. So the decoder **synthesises a virtual field 253** and inserts it into the
data record's field dictionary.

`FITDecoder.swift:189-194`:

```swift
// Inject field 253 (timestamp) so parsers can use it normally.
if message.fields[253] == nil {
    var fields = message.fields
    fields[253] = .uint32(newTimestamp)
    message = FITMessage(globalMessageNumber: message.globalMessageNumber, fields: fields)
}
```

Existing parsers (`ActivityFITParser`, `SleepFITParser`, `MonitoringFITParser`,
`MetricsFITParser`) all read `fields[253]` via `FITTimestamp.date(from:)` and never need
to know whether the timestamp was on the wire as a real field or synthesised from the
record header.

The injection is **conditional** — if the message definition *did* declare field 253 and
the record carries an explicit value, the decoder leaves it alone. This handles malformed
or unusual files where a writer set bit 7 in the header but also declared field 253.

---

## 4. Resetting the baseline: msg 162 (`timestamp_correlation`)

FIT msg 162 (`timestamp_correlation`) carries `timestamp` (field 253, UTC) and
`local_timestamp` (field 3). It is typically emitted near the start of monitoring/HSA
files to anchor the file's clocks and serves as a fresh non-compressed timestamp baseline
that subsequent compressed-timestamp records can build on.

In Compass the decoder does not special-case msg 162; the generic rule "any data record
with field 253 updates `lastTimestamp`" (`FITDecoder.swift:210-212`) does the right thing.
Parsers do not currently extract the local timestamp / TZ offset, but the message is
listed in the field-name overlay (`harry_overlay.json`) for completeness.

Reference: see [`messages.md`](messages.md) §"Message 162".

---

## 5. The msg 233 special case

> **Important:** msg 233 (`monitoring_v2`) records seen on Instinct Solar 1G fw 19.1 use a
> *normal* (non-compressed) record header, but their field definition does not include
> field 253. These records have **no per-record timestamp at all** — the file's timestamps
> come from surrounding records (msg 162, msg 55).

This is *not* a compressed-timestamp situation. The decoder will not synthesise field 253
for these records because:

- bit 7 of the header is 0 → the compressed-timestamp branch is skipped
  (`FITDecoder.swift:169`)
- the field dictionary built by `readDataMessage` has no field 253 because the definition
  did not declare it (`FITDecoder.swift:333-343`)
- `lastTimestamp` is still updated whenever an explicit field-253 record appears (e.g.
  every msg 55), so the file's timestamp cursor remains coherent — but msg 233 records
  themselves come back with `fields[253] == nil`

The current `MonitoringFITParser` therefore field-dumps msg 233 (logged at INFO level) and
does not attempt to assign timestamps to those records (`MonitoringFITParser.swift:149-159`).
For Instinct Solar 1G the per-second health data lives in msgs 306–314 (HSA family),
inside subtype-58 files, and msg 233 in subtype-32 files only carries a 4-byte payload of
unknown meaning. See [`messages.md`](messages.md) §"Message 233" and the Instinct Solar
device notes (cross-link below).

---

## 6. Edge cases the decoder handles

- **Compressed timestamp before any baseline.** If a compressed-timestamp record appears
  before any field-253 record has set `lastTimestamp`, the baseline is 0, so the
  reconstructed timestamp will be `time_offset` (i.e. seconds since 1989-12-31). This is
  almost certainly wrong but real files do not do this — every Garmin file Compass has
  seen begins with `file_id` (msg 0, no timestamp) followed by a `device_info` (msg 23,
  field 253) or `timestamp_correlation` (msg 162, field 253) before any compressed records.
- **Undefined local type.** A compressed-timestamp record references local types 0–3, but
  if no definition exists for the referenced local type, the decoder logs a warning and
  cannot continue safely (it does not know how many bytes of payload to skip). The current
  behaviour is `continue` — i.e. drop the record header and try the next byte
  (`FITDecoder.swift:174-177`). This is best-effort recovery for malformed files; a clean
  Garmin file never hits this path.
- **`lastTimestamp` updates from compressed records.** After successfully reconstructing
  `newTimestamp`, the decoder writes it back to `lastTimestamp`
  (`FITDecoder.swift:188`), so a sequence of compressed records can chain across many
  rollovers — each one's reconstruction depends only on the previous one's reconstruction,
  not on the original anchor.

---

## 7. What Compass does not (yet) do

- **Emit compressed timestamps.** `CourseFITEncoder` writes only normal headers and
  explicit field 253 in record/lap messages. Course files are tiny (one record per
  waypoint, typically a few hundred records) so the byte savings would be negligible.
- **Validate the file CRC.** Out of scope here; see
  [`format.md`](format.md) §"File CRC".

---

## Source

- `Packages/CompassFIT/Sources/CompassFIT/Parsers/FITDecoder.swift` lines 163-194 (cursor,
  branch, rule, injection); 210-212 (cursor update on explicit field 253)
- `Packages/CompassFIT/Sources/CompassFIT/Parsers/MonitoringFITParser.swift` lines 149-159
  (msg 233 field dump rationale)
- See also: [`format.md`](format.md), [`messages.md`](messages.md)

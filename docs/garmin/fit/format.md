# FIT File Format — Reference

_Source-derived from `Packages/CompassFIT/Sources/CompassFIT/Parsers/FITDecoder.swift` and
`Encoders/CourseFITEncoder.swift`. External references: Garmin FIT SDK (`profile.py`),
HarryOnline spreadsheet, Gadgetbridge `RecordHeader.java`._

The FIT (Flexible and Interoperable Data Transfer) format is the binary serialization used
by every Garmin watch for activity, monitoring, sleep, and metrics files. A FIT file is a
self-describing stream of typed records. Every data record is preceded (somewhere earlier
in the file) by a definition record that names its fields and their types; the same
"local message number" can be redefined any number of times within a file.

This document describes the wire format as Compass actually parses and emits it. For the
catalog of message types Compass cares about, see [`messages.md`](messages.md). For the
compressed-timestamp shortcut (record header bit 7), see [`compressed-timestamps.md`](compressed-timestamps.md).

---

## 1. File layout

```
+------------------------+
| Header (12 or 14 B)    |
+------------------------+
| Records (data_size B)  |   ← interleaved definitions and data records
+------------------------+
| File CRC (2 B, LE)     |   ← CRC-16 over [records] only
+------------------------+
```

The header declares how many bytes of records follow. The decoder reads exactly that many,
then the trailing CRC. Anything past the trailing CRC is ignored — Garmin sometimes
chains multiple "FIT chunks" back-to-back; Compass currently only decodes the first chunk
(see `FITDecoder.decode` at `FITDecoder.swift:150`).

---

## 2. The header

A FIT header is either 12 or 14 bytes. The first byte declares its size.

| Offset | Size | Field             | Notes                                             |
|-------:|-----:|-------------------|---------------------------------------------------|
| 0      | 1    | header_size       | 12 or 14 — see below                              |
| 1      | 1    | protocol_version  | High nibble = major, low nibble = minor (BCD-ish) |
| 2      | 2    | profile_version   | uint16 LE                                         |
| 4      | 4    | data_size         | uint32 LE — bytes of records that follow header   |
| 8      | 4    | data_type         | ASCII `.FIT` (`0x2E 0x46 0x49 0x54`)              |
| 12     | 2    | header_crc        | uint16 LE — present only when header_size == 14   |

Compass enforces the magic at `FITDecoder.swift:246`. If `header_size > 12` and not 14, the
extra bytes are skipped (`FITDecoder.swift:253-256`); only headers of exactly 14 bytes get
their CRC parsed (and then ignored — Compass does not validate it on read).

### What Compass writes

`CourseFITEncoder` always emits a 14-byte header
(`CourseFITEncoder.swift:154-168`):

| Field            | Value                                              |
|------------------|----------------------------------------------------|
| header_size      | `14`                                               |
| protocol_version | `16` (`0x10`, "protocol 2.0" in Garmin's scheme)   |
| profile_version  | `2134`                                             |
| data_size        | computed from emitted body                         |
| data_type        | `.FIT`                                             |
| header_crc       | CRC-16 over the preceding 12 bytes                 |

Garmin allows `0x0000` for header_crc ("not computed"), but the on-watch indexer prefers a
real value, so Compass always computes it.

---

## 3. Records: the body of the file

Within `data_size` bytes there are interleaved **definition** records and **data** records,
plus the optional shorthand of a **compressed-timestamp data** record. The first byte of
every record — the **record header byte** — distinguishes them.

```
record_header bit layout

  bit  7   = compressed_timestamp_flag
                1 → compressed-timestamp data record (see compressed-timestamps.md)
                0 → normal record (definition or data)

  for normal records (bit 7 == 0):
    bit  6   = message_type
                  1 → definition message
                  0 → data message
    bit  5   = developer_data_flag (definition only)
    bit  4   = reserved (must be 0)
    bits 3-0 = local_message_type (0–15)
```

Decoder dispatch is at `FITDecoder.swift:165-214`.

The **local message type** (4 bits, 0–15) is a small index into a per-file table of
definitions. A given local type starts undefined; once a definition record sets it, every
subsequent data record with the same local type is decoded against that definition until
the local type is redefined.

### 3.1 Definition record

After the record header byte, a definition record looks like this:

| Offset | Size | Field                | Notes                                       |
|-------:|-----:|----------------------|---------------------------------------------|
| 0      | 1    | reserved             | must be 0                                   |
| 1      | 1    | architecture         | `0` = little-endian, `1` = big-endian       |
| 2      | 2    | global_message_num   | uint16 in declared endianness               |
| 4      | 1    | num_fields           | how many field defs follow                  |
| 5      | 3 × num_fields | field_def[n] | (field_def_num, size, base_type)            |

If bit 5 of the record header byte was set (developer-data flag), an additional
`num_dev_fields (1 byte) + 3 × num_dev_fields` is appended after the standard field defs:

| Field              | Size | Notes                                               |
|--------------------|-----:|-----------------------------------------------------|
| dev_field_num      | 1    | references a previously-defined `field_description` |
| dev_field_size     | 1    | size in bytes                                       |
| dev_data_index     | 1    | references a `developer_data_id`                    |

**Compass does not interpret developer fields.** They are read off the wire to keep the
cursor aligned and then discarded (`FITDecoder.swift:346-351`). Files with developer fields
still decode cleanly — Compass simply does not surface them.

#### Field definition triplet

Each standard field def is three bytes:

| Byte | Field        | Notes                                      |
|-----:|--------------|--------------------------------------------|
| 0    | field_def_num | the field number this message type uses   |
| 1    | size          | total bytes (so an array of N uint16 = 2N) |
| 2    | base_type     | one of the values in §4                    |

`size` may be larger than the natural element width; that signals an array. For example, a
`uint8[16]` field has size=16, base_type=0x02, and decodes as `Data` (Compass reads it as
`FITFieldValue.data(...)`, then individual parsers reinterpret the bytes — see
[`messages.md`](messages.md) on the HSA family for an example).

### 3.2 Data record

After the record header byte (bit 6 = 0, bit 7 = 0), a data record is a flat concatenation
of every field listed in the matching local-type definition, in **definition order**. There
is no field tag in a data record; field identity is purely positional, derived from the
definition.

The Compass decoder builds a `[UInt8: FITFieldValue]` dictionary keyed by `field_def_num`
so downstream code can read by field number, not by position
(`FITDecoder.swift:333-353`).

If a definition declares developer fields, those bytes appear at the end of each data
record and are skipped over (`FITDecoder.swift:346-351`).

### 3.3 Compressed-timestamp data record

When the record header has bit 7 set, the rest of the byte encodes a 2-bit local message
type (bits 6-5) and a 5-bit time delta (bits 4-0). No timestamp is on the wire; the decoder
synthesises one. See [`compressed-timestamps.md`](compressed-timestamps.md).

---

## 4. Base types

The base-type byte is 8 bits with two meanings packed in:

```
  bit  7   = endian_capable (informational)
  bits 6-5 = reserved
  bits 4-0 = type_number
```

In practice the decoder switches on the full byte (`FITDecoder.swift:359-377`):

| Byte | Name      | Wire repr                | Compass mapping (`FITFieldValue`) | Invalid sentinel |
|-----:|-----------|--------------------------|------------------------------------|------------------|
| 0x00 | enum      | 1 B                      | `.enumValue(UInt8)`                | 0xFF             |
| 0x01 | sint8     | 1 B signed               | `.int8(Int8)`                      | 0x7F             |
| 0x02 | uint8     | 1 B                      | `.uint8(UInt8)`                    | 0xFF             |
| 0x83 | sint16    | 2 B signed, declared end | `.int16(Int16)`                    | 0x7FFF           |
| 0x84 | uint16    | 2 B, declared end        | `.uint16(UInt16)`                  | 0xFFFF           |
| 0x85 | sint32    | 4 B signed, declared end | `.int32(Int32)`                    | 0x7FFFFFFF       |
| 0x86 | uint32    | 4 B, declared end        | `.uint32(UInt32)`                  | 0xFFFFFFFF       |
| 0x07 | string    | N B, null-terminated     | `.string(String)`                  | empty/all-zero   |
| 0x88 | float32   | 4 B IEEE-754             | `.float32(Float)`                  | 0xFFFFFFFF       |
| 0x89 | float64   | 8 B IEEE-754             | `.float64(Double)`                 | 0xFFFFFFFFFFFFFFFF |
| 0x0A | uint8z    | 1 B (0 = invalid)        | `.uint8(UInt8)`                    | 0x00             |
| 0x8B | uint16z   | 2 B (0 = invalid)        | `.uint16(UInt16)`                  | 0x0000           |
| 0x8C | uint32z   | 4 B (0 = invalid)        | `.uint32(UInt32)`                  | 0x00000000       |
| 0x0D | byte      | N B opaque               | `.data(Data)`                      | per-byte 0xFF    |
| 0x8E | sint64    | 8 B signed, declared end | `.int64(Int64)`                    | 0x7FFF…FF        |
| 0x8F | uint64    | 8 B, declared end        | `.uint64(UInt64)`                  | 0xFFFF…FF        |
| 0x90 | uint64z   | 8 B (0 = invalid)        | `.uint64(UInt64)`                  | 0                |

Anything else falls through to a raw `Data` slice of the declared size
(`FITDecoder.swift:464-466`).

### 4.1 The "z" types

`uint8z`, `uint16z`, `uint32z`, `uint64z` are interpreted exactly like their non-`z`
counterparts on the wire — Compass does not distinguish them in `FITFieldValue`. The only
semantic difference is **the sentinel value for "invalid" is 0 instead of all-ones**. When
emitting, `CourseFITEncoder` writes `serial_number = 0` even though it is declared as
`uint32z` (`CourseFITEncoder.swift:199, 210`); Garmin watches accept this without
complaint for development manufacturer 255.

### 4.2 Strings

A FIT string is a fixed-size byte array; the actual string ends at the first null byte.
Compass strips trailing nulls and decodes the remainder as UTF-8 (`FITDecoder.swift:441-446`).

### 4.3 Arrays

Array fields use the underlying base type with `size = elem_size × N`. The decoder
recognises this only for sint8/uint8 (where `size > 1`) and `byte` (always `Data`); for
larger element types with size mismatch it falls back to raw `.data` bytes
(`FITDecoder.swift:401-419`). The HSA messages 306, 307, 308, 314 in
[`messages.md`](messages.md) all use array fields and Compass parsers reinterpret them via
`FITFieldValue.uint8Array` / `int8Array`.

---

## 5. Endianness

Endianness is per-definition, declared in byte 1 of every definition record. Both LE and BE
are supported by the decoder (`FITDecoder.swift:289-299, 333-343`); CourseFITEncoder always
writes LE. Within a single file, different local types may use different endiannesses,
though real Garmin files are uniformly LE.

---

## 6. Scale and offset

The base type byte specifies how to read raw bytes. The interpretation as a physical
quantity is the parser's job, using per-message scale/offset constants from the Garmin FIT
SDK profile. Common patterns Compass applies:

| Quantity              | Where                            | Formula                              |
|-----------------------|----------------------------------|--------------------------------------|
| Position (lat/long)   | record (msg 20) fields 0/1       | `degrees = semicircles × 180/2³¹`   |
| Altitude              | record field 2                   | `metres = (raw / 5) − 500`           |
| Speed                 | record field 6                   | `m/s = raw / 1000`                   |
| Distance              | session/lap fields 9             | `metres = raw / 100`                 |
| Total elapsed time    | session field 7                  | `seconds = raw / 1000`               |
| Heart rate, cadence   | record fields 3, 4               | identity (units bpm, rpm)            |
| Temperature           | record field 13                  | identity (°C)                        |

Conversions are concentrated in `ActivityFITParser.swift:99-114` (decode) and
`CourseFITEncoder.swift:418-425` (encode). The semicircles factor is computed exactly as
`180 / 2³¹` to avoid float drift (`ActivityFITParser.swift:44`). FIT defines a sentinel
0xFFFFFFFF for invalid uint32 values; `ActivityFITParser` guards against it explicitly for
distance (`ActivityFITParser.swift:144`).

---

## 7. Garmin epoch and FIT timestamps

All FIT `date_time` fields (base type uint32, denoted `0x86`) are **seconds since
1989-12-31T00:00:00Z**, the so-called Garmin epoch. The offset from Unix epoch
(1970-01-01T00:00:00Z) is **+631 065 600 seconds**.

Compass's reference is computed from broken-down components in
`FITTimestamp.swift:8-20`:

```swift
public static let epoch: Date = {
    var components = DateComponents()
    components.year = 1989; components.month = 12; components.day = 31
    components.hour = 0; components.minute = 0; components.second = 0
    components.timeZone = TimeZone(identifier: "UTC")
    return Calendar(identifier: .gregorian).date(from: components)!
}()
```

`FITTimestamp.date(fromFITTimestamp:)` adds the raw uint32 directly as a `TimeInterval`. The
upper bound is 2156-02-07T06:28:15Z, so 32-bit Garmin timestamps will not overflow within
any realistic device lifetime.

A test in `FITDecoderTests.swift:254-265` verifies that uint32 timestamp 0 decodes to
1989-12-31 UTC.

### timestamp_16 (compact-HR variant)

Some firmwares (Instinct 2 Solar Surf) embed a 16-bit truncated timestamp instead of the
full 32-bit value in monitoring messages — see
`MonitoringFITParser.swift:300-308` for the resolution rule. This is unrelated to the
compressed-timestamp record header in §3.3 / `compressed-timestamps.md`.

---

## 8. File CRC (footer)

The last two bytes of the file are a CRC-16 over **every byte after the header** (i.e. the
records area only — header bytes are excluded). Algorithm: 4-bit-table lookup, polynomial
0xA001 reversed; Garmin nibble-table form.

The 16-entry table is in `FITDecoder.swift:558-565` and reproduced in
`CourseFITEncoder.swift:441-446`:

```
0x0000 0xCC01 0xD801 0x1400 0xF001 0x3C00 0x2800 0xE401
0xA001 0x6C00 0x7800 0xB401 0x5000 0x9C01 0x8801 0x4400
```

For each input byte the algorithm processes the low nibble first, then the high nibble:

```swift
var tmp = table[Int(crc & 0xF)]
crc = (crc >> 4) & 0x0FFF
crc = crc ^ tmp ^ table[Int(byte & 0xF)]
tmp = table[Int(crc & 0xF)]
crc = (crc >> 4) & 0x0FFF
crc = crc ^ tmp ^ table[Int((byte >> 4) & 0xF)]
```

(`FITDecoder.swift:568-582`.) The same routine computes the optional **header CRC** in the
14-byte form (`CourseFITEncoder.swift:167`).

The decoder does **not** validate the file CRC on read (no `crcMismatch` is thrown by
`FITDecoder.decode`); CRC verification is reserved for tooling and the encoder's
self-check. This matches the file-format spec, which makes CRC verification optional for
readers but mandatory for writers.

For the broader CRC-16 used elsewhere in Garmin (BLE GFDI), see
[`../transport/crc16.md`](../transport/crc16.md) (separate document; same algorithm,
different framing context).

---

## 9. Developer fields (extension)

The FIT 2.0 protocol added **developer data**: third-party fields described in-stream by
two extra messages (`developer_data_id`, `field_description`). A definition record
references them via the developer-data flag and the dev-field triplets in §3.1.

**Compass does not interpret developer fields.** Real Garmin watch files do not contain
them, so the decoder maintains correct cursor alignment by skipping the declared bytes
(`FITDecoder.swift:312-321, 346-351`) and otherwise ignores the extension. Files that
include developer fields decode correctly; the developer values are simply dropped.

---

## 10. End-to-end decoder flow

`FITDecoder.decode(data:)` (`FITDecoder.swift:150-218`):

1. Read the header; assert magic; respect the declared header size.
2. Compute `dataEnd = headerSize + dataSize`.
3. Maintain `definitions: [UInt8: LocalMessageDefinition]` (per local type) and
   `lastTimestamp: UInt32` (the running compressed-timestamp baseline).
4. Loop while `reader.offset < dataEnd`:
   - Read one record header byte.
   - If bit 7 is set → compressed-timestamp data record (see
     [`compressed-timestamps.md`](compressed-timestamps.md)).
   - Else if bit 6 is set → definition record; replace `definitions[localType]`.
   - Else → data record; decode against `definitions[localType]`. If field 253 is present,
     update `lastTimestamp`.
5. Return `FITFile(messages: …)`. The trailing 2 CRC bytes are left unread.

The output is a flat ordered list of `FITMessage`s; downstream parsers
(`ActivityFITParser`, `MonitoringFITParser`, `SleepFITParser`, `MetricsFITParser`) iterate
this list and dispatch on `globalMessageNumber` — see [`messages.md`](messages.md).

---

## Source

- `Packages/CompassFIT/Sources/CompassFIT/Parsers/FITDecoder.swift`
  (lines 150-218 dispatch loop, 231-266 header, 289-329 definition, 333-353 data,
   379-468 base-type decode, 558-582 CRC)
- `Packages/CompassFIT/Sources/CompassFIT/Parsers/FITTimestamp.swift` (Garmin epoch)
- `Packages/CompassFIT/Sources/CompassFIT/Encoders/CourseFITEncoder.swift`
  (lines 151-178 header+CRC, 405-435 helpers, 440-458 CRC)
- `Packages/CompassFIT/Tests/CompassFITTests/FITDecoderTests.swift` (test fixtures)

External, not bundled with Compass:
- Garmin FIT SDK (`Profile.xlsx`, `profile.py`)
- Gadgetbridge `app/src/main/java/.../service/devices/garmin/fit/RecordHeader.java`
- HarryOnline Garmin FIT extensions spreadsheet

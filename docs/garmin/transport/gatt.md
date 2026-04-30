# GATT Transport — Garmin V2 Multi-Link

The Bluetooth Low Energy GATT layer is the bottom of the Compass Garmin
stack. Every byte that the iOS app exchanges with the watch eventually
passes through one of two characteristics on a single Garmin BLE service.
This document describes the Compass implementation and notes where it
diverges from the Gadgetbridge reference.

Source of truth: `Compass: BluetoothCentral.swift` (603 lines).

---

## Service & characteristic UUIDs

The Garmin V2 ML GATT service derives all its UUIDs from a single 128-bit
base, varying only the 16-bit field at offset 2:

```
6A4E____-667B-11E3-949A-0800200C9A66
```

| 16-bit suffix | Role                              | Notes |
|---------------|-----------------------------------|-------|
| `2800`        | Service                           | V2 ML GFDI service |
| `2810`        | Notify (watch → phone)            | "receive" channel 0 |
| `2820`        | Write  (phone → watch)            | "send"    channel 0 |
| `2811…2814`   | Notify (alternate channels)       | Future / variant firmware |
| `2821…2824`   | Write  (alternate channels)       | Future / variant firmware |

Compass also probes two legacy V1 fallback UUIDs (`Compass:
BluetoothCentral.swift:318-319`):

| Suffix | Role                  |
|--------|-----------------------|
| `2801` | V1 write              |
| `2802` | V1 notify             |

V0 service `9B012401-BC30-CE9A-E111-0F67E491ABDE` is included in the
service discovery filter (`Compass: BluetoothCentral.swift:43`) but no V0
characteristic resolver is wired up.

Reference: Gadgetbridge `CommunicatorV2.java:50-65`. The Java side derives
both UUIDs from `BASE_UUID = "6A4E%04X-667B-11E3-949A-0800200C9A66"` and
loops `i = 0x2810 ... 0x2814`, pairing each receive with `i + 0x10` —
`Gadgetbridge: CommunicatorV2.java:88-100`.

---

## Service & characteristic discovery

### Compass behaviour

`Compass: BluetoothCentral.swift:260-348` performs:

1. `discoverServices(allGarminServiceUUIDs)` — filters to the three known
   service UUIDs (V0, V1, V2) on the peripheral side.
2. Picks the first match from the `services` array; preference order is
   array-discovery order, which usually surfaces V2 first.
3. `discoverCharacteristics(nil, …)` — discovers **all** characteristics
   on the chosen service so they can be logged for debugging.
4. Resolves the V2 send/notify pair first (`2820` / `2810`); falls back to
   V1 (`2801` / `2802`) only if either V2 char is missing.

### Known divergence — narrow channel scan

Gadgetbridge probes the entire `0x2810 … 0x2814` range and uses the first
pair where both `28x0` notify and `28x0+0x10` write coexist. Compass only
checks suffix `0x2810/0x2820` (V2) and `0x2801/0x2802` (legacy V1). If a
future firmware exposes only `0x2811/0x2821` or higher channels, Compass
will fail discovery and surface
`PairingError.authenticationFailed("Required BLE characteristics not found
on device")` (`Compass: BluetoothCentral.swift:346`).

This works today because every observed firmware (including Instinct
Solar 1G) advertises `2810/2820`.

---

## Scanning

Garmin watches **do not always advertise the V2 service UUID** in their
LE advertisement / scan response. Filtering scans by service UUID misses
the device entirely on Instinct Solar and several other models.

Compass mirrors Gadgetbridge's strategy: scan for **all** BLE peripherals
with no service filter (`Compass: BluetoothCentral.swift:169-172`), then
post-filter discovered devices by name prefix (`Compass:
BluetoothCentral.swift:441-449`).

The prefix list (`Compass: BluetoothCentral.swift:48-54`) covers
`Instinct`, `Forerunner`, `Fenix`, `fenix`, `Enduro`, `Venu`,
`vivoactive`, `vivomove`, `vivosmart`, `vivofit`, `Lily`, `Approach`,
`Descent`, `MARQ`, `tactix`, `Tactix`, `Swim`, `Edge`, `D2`, `epix`,
`Epix`, `quatix`, `Quatix`, `Garmin`. Non-Garmin advertisers are silently
dropped to avoid log spam.

Reference: Gadgetbridge `DiscoveryActivityV2` — same approach (no service
filter; name-prefix matching).

---

## Write semantics

### What Compass does today

`Compass: BluetoothCentral.swift:395` issues every characteristic write
as **`.withResponse`**:

```swift
peripheral.writeValue(next.data, for: characteristic, type: .withResponse)
```

This contradicts the surrounding docstring at `Compass:
BluetoothCentral.swift:354-360`, which still claims `.withoutResponse` is
used. The shipping behaviour is `.withResponse`.

### Why this is a known divergence

The Garmin send characteristic only declares `WRITE_NO_RESPONSE` in its
GATT properties, not `WRITE`. The matching iOS write type is
`.withoutResponse` (ATT Write Command). Gadgetbridge writes every byte as
`WRITE_TYPE_NO_RESPONSE` because Android's `getWriteType()` returns the
characteristic's only declared property — see `Gadgetbridge:
WriteAction.java:81-86` and the rationale in `Gadgetbridge:
WriteAction.java:58-62`.

### Why it works empirically

iOS does not refuse `.withResponse` on a characteristic that only
advertises `WriteWithoutResponse` — it sends an ATT Write Request anyway.
On Instinct Solar 1G the watch firmware **does** emit a Write Response
PDU and CoreBluetooth fires `peripheral(_:didWriteValueFor:error:)`,
which lets Compass serialise writes through the FIFO write queue
(`Compass: BluetoothCentral.swift:107-396`). Without the Write Response
callback the queue would deadlock — and indeed it would on a strictly
spec-compliant peripheral.

If Compass is ever ported to firmware that follows the GATT spec
strictly, the write type must be flipped to `.withoutResponse` and a
different serialisation mechanism (poll `canSendWriteWithoutResponse`,
back off on `peripheralIsReady(toSendWriteWithoutResponse:)`) wired in.
A skeleton for that already exists at `Compass:
BluetoothCentral.swift:401-405` and `:118` (currently unused —
`didBecomeReadyToWrite()` "never fires in practice").

---

## Write serialisation

Concurrent `MultiLinkTransport.sendGFDI(_)` callers and management
writes (`CLOSE_ALL_REQ`, `REGISTER_ML_REQ`) must not race each other into
`peripheral.writeValue`, or one of two failure modes occurs:

* Two `CheckedContinuation`s land on the same `didWriteValueFor`, leaking
  one and triggering the runtime's "SWIFT TASK CONTINUATION MISUSE"
  warning.
* iOS coalesces or drops back-to-back writes when the LL queue is busy.

Compass enforces serialisation with a FIFO `writeQueue:
[PendingWrite]` (`Compass: BluetoothCentral.swift:107`) plus a single
`inflightWrite` slot (`Compass: BluetoothCentral.swift:111`). The pump
pulls one entry, hands it to `peripheral.writeValue`, and waits for
`didWriteValue(error:)` (`Compass: BluetoothCentral.swift:522-534`)
before draining the next.

`MultiLinkTransport` adds a second per-message lock (`sendInFlight`,
`Compass: MultiLinkTransport.swift:62-63, 127-132`) so all fragments of a
multi-fragment GFDI message reach `central.write()` contiguously. See
[multi-link.md](multi-link.md#fragmentation).

---

## MTU / max write size

`peripheral.maximumWriteValueLength(for: .withResponse)` is exposed as
`negotiatedMTU` (`Compass: BluetoothCentral.swift:419-423`). On iOS the
ATT MTU is auto-negotiated; the app cannot request a specific value.

Despite iOS often reporting 512 after MTU exchange, Compass deliberately
caps `maxWriteSize` at 20 bytes (`Compass: MultiLinkTransport.swift:86-96`).
Older Instinct Solar 1G firmware does not reliably handle ATT writes that
span multiple LL packets — sending a 26-byte write hangs forever waiting
for an ATT Write Response that never comes. Inbound notifications from
the watch are also chunked at 20 bytes; mirroring that on the outbound
side keeps the link symmetric.

---

## Disconnect handling

`Compass: BluetoothCentral.swift:218-250, 464-488` clears all
characteristic state, finishes the `notifications()` AsyncStream, and
fails every queued / inflight write with `PairingError.deviceNotFound`.
A `disconnectHandler` callback (`:121, 129-131, 487`) lets the
`MultiLinkTransport` / `GFDIClient` layers tear down their own state
when the link drops unexpectedly.

---

## Source

* `Compass: Packages/CompassBLE/Sources/CompassBLE/Transport/BluetoothCentral.swift`
* `Compass: Packages/CompassBLE/Sources/CompassBLE/Transport/MultiLinkTransport.swift`
* `Gadgetbridge: service/devices/garmin/communicator/v2/CommunicatorV2.java:50-100`
* `Gadgetbridge: service/btle/actions/WriteAction.java:58-86`
* `docs/garmin/references/gadgetbridge-pairing.md` §1, §2

Cross-references: [multi-link.md](multi-link.md), [cobs.md](cobs.md),
[crc16.md](crc16.md).

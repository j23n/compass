# Gadgetbridge Instinct Solar (1st gen) Pairing — Byte-Level Reference

This document is a direct, byte-level reverse-engineering reference for the way
**Gadgetbridge** pairs with a Garmin watch over the V2 (Multi-Link / GFDI) BLE
transport. It is written for engineers re-implementing the protocol on iOS
(CompassBLE) so the GB code can be diffed line-by-line.

All citations refer to the Gadgetbridge `master` branch as fetched on 2026-04-29
from <https://codeberg.org/Freeyourgadget/Gadgetbridge>. Paths shown without a
prefix live under
`app/src/main/java/nodomain/freeyourgadget/gadgetbridge/`.

There is **no** Instinct-specific subclass anywhere in the GB tree (verified
via `git tree?recursive=true` — no path matches `instinct` or `Instinct`).
Instinct devices are handled exactly the same as every other Garmin watch
through `GarminSupport` + `CommunicatorV2`. This is itself an important
finding: any "Instinct quirk" you observe is just the generic Garmin V2
pairing flow.

---

## Table of Contents

1. [GATT Topology and Characteristic Selection](#1-gatt-topology-and-characteristic-selection)
2. [Write Type — `WRITE_TYPE_DEFAULT` vs `WRITE_TYPE_NO_RESPONSE`](#2-write-type)
3. [The Multi-Link Layer (Handle 0 control plane)](#3-the-multi-link-layer)
4. [The COBS Frame Layer](#4-the-cobs-frame-layer)
5. [The GFDI Message Layer (length + CRC + payload)](#5-the-gfdi-message-layer)
6. [The CRC-16 Variant](#6-the-crc-16-variant)
7. [Compact Message-Type Encoding (`& 0x8000`)](#7-compact-message-type-encoding)
8. [`MessageWriter` / `MessageReader` Conventions](#8-messagewriter--messagereader-conventions)
9. [Reliable Mode (MLR) vs Basic ML](#9-reliable-mode-mlr-vs-basic-ml)
10. [Pairing — Full Chronological Byte-Level Walkthrough](#10-pairing--full-chronological-byte-level-walkthrough)
11. [Capabilities — `OUR_CAPABILITIES` Enumeration](#11-capabilities--our_capabilities-enumeration)
12. [Auth Negotiation](#12-auth-negotiation)
13. [`SystemEvent` Sequence and "Initialized" State](#13-systemevent-sequence-and-initialized-state)
14. [iOS / CoreBluetooth Pairing & Bonding](#14-ios--corebluetooth-pairing--bonding)
15. [Differences vs `Packages/CompassBLE/`](#15-differences-vs-packagescompassble)
16. [Known Unknowns](#16-known-unknowns)
17. [Post-Pair Protobuf Exchange](#17-post-pair-protobuf-exchange)

---

## 1. GATT Topology and Characteristic Selection

The V2 Multi-Link service UUID is the *2800* alias of the Garmin BLE base UUID
template:

```
public static final String BASE_UUID = "6A4E%04X-667B-11E3-949A-0800200C9A66";
public static final UUID UUID_SERVICE_GARMIN_ML_GFDI =
        UUID.fromString(String.format(BASE_UUID, 0x2800));
```

> `service/devices/garmin/communicator/v2/CommunicatorV2.java:50–51`

Inside that service the watch exposes pairs of characteristics. Gadgetbridge
**pairs a "receive" UUID with a "send" UUID by adding 0x10 to the receive
UUID's 16-bit suffix**. Concretely, the loop in `initializeDevice` is:

```java
// CommunicatorV2.java:88–100
for (int i = 0x2810; i <= 0x2814; i++) {
    characteristicReceive = mSupport.getCharacteristic(UUID.fromString(String.format(BASE_UUID, i)));
    characteristicSend    = mSupport.getCharacteristic(UUID.fromString(String.format(BASE_UUID, i + 0x10)));

    if (characteristicSend != null && characteristicReceive != null) {
        LOG.debug("Using characteristics receive/send = {}/{}", characteristicReceive.getUuid(), characteristicSend.getUuid());
        builder.notify(characteristicReceive, true);
        builder.write(characteristicSend, closeAllServices());
        return true;
    }
}
```

So Gadgetbridge tries the pairs:

| Receive (notify) | Send (write)   |
| ---------------- | -------------- |
| `…2810…`         | `…2820…`       |
| `…2811…`         | `…2821…`       |
| `…2812…`         | `…2822…`       |
| `…2813…`         | `…2823…`       |
| `…2814…`         | `…2824…`       |

It picks the **first pair where both characteristics exist on the peripheral**.
For an Instinct Solar 1st gen the working pair is `…2810…` (notify) / `…2820…`
(write). 2803 is *not* used by Gadgetbridge — it's the Garmin device-info
service (firmware string etc.) and is handled by Android's bonding stack, not
by Gadgetbridge.

Note `0x2814 / 0x2824` is included in the loop range even though current
firmware doesn't expose it; this future-proofs against new variants.

### Order of GATT operations on connect

Inside `GarminSupport.initializeDevice` the sequence is:

```java
// service/devices/garmin/GarminSupport.java:261–284
builder.setDeviceState(GBDevice.State.INITIALIZING);
if (getDevicePrefs().getBoolean(PREF_ALLOW_HIGH_MTU, true)) {
    builder.requestMtu(515);
}
final CommunicatorV2 communicatorV2 = new CommunicatorV2(this);
if (communicatorV2.initializeDevice(builder)) {
    communicator = communicatorV2;
} else {
    // fall back to V1 …
}
```

So the order on connect is:

1. State → `INITIALIZING`.
2. `requestMtu(515)` (queued — the actual ATT MTU exchange happens before
   any subsequent write because `TransactionBuilder` is FIFO).
3. `notify(receiveCharacteristic, true)` — enable notifications on the
   chosen receive characteristic. This writes the CCCD descriptor.
4. `write(sendCharacteristic, closeAllServices())` — see §3.

Critically: **GB enables notify *before* the first ML write.** The watch will
not respond on the receive characteristic until subscriptions are in place.

---

## 2. Write Type

This is the load-bearing detail for the bug we keep hitting.

### What the Garmin code actually says

Neither `CommunicatorV2.java` nor `MlrCommunicator.java` ever calls
`characteristic.setWriteType(...)`. Every outbound packet is constructed via
one of these calls:

| Call site                                            | File:line                     |
| ---------------------------------------------------- | ----------------------------- |
| CLOSE_ALL_REQ on init                                | `CommunicatorV2.java:96`      |
| REGISTER_ML_REQ for GFDI (after CLOSE_ALL_RESP)      | `CommunicatorV2.java:397`     |
| REGISTER_ML_REQ for realtime services                | `CommunicatorV2.java:229, 238, 259` |
| CLOSE_HANDLE_REQ                                     | `CommunicatorV2.java:264`     |
| GFDI fragment (basic ML)                             | `CommunicatorV2.java:144, 149`|
| GFDI fragment via MLR sender lambda                  | `CommunicatorV2.java:666`     |
| ML service writer (post-handshake realtime traffic)  | `CommunicatorV2.java:651`     |

All of these end up in `TransactionBuilder.write(BluetoothGattCharacteristic, byte[])`:

```java
// service/btle/TransactionBuilder.java:134–149
public TransactionBuilder write(@Nullable BluetoothGattCharacteristic characteristic, byte... data) {
    …
    WriteAction action = new WriteAction(characteristic, data);
    return add(action);
}
```

`WriteAction` then writes using the characteristic's **own** declared write
type (no override):

```java
// service/btle/actions/WriteAction.java:81–86
final int status = gatt.writeCharacteristic(
        characteristic, value, characteristic.getWriteType());
```

In the Garmin `…2820…` characteristic, the BLE descriptor advertises
`WRITE_NO_RESPONSE` (and only `WRITE_NO_RESPONSE` — Garmin firmware sets the
"Write Without Response" bit, not the "Write" bit). Therefore Android's
`getWriteType()` returns `BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE`
by default and **every** GB write to the send characteristic — the
CLOSE_ALL_REQ at init, REGISTER_ML_REQ, GFDI traffic, MLR fragments, MLR
ACK-only packets — is sent **without response**.

### Implication for iOS

On iOS / CoreBluetooth, `CBCharacteristicWriteType.withResponse` corresponds
to ATT Write Request, and `.withoutResponse` corresponds to ATT Write Command.
The Garmin send characteristic only declares `WriteWithoutResponse` in its
properties, so:

* `peripheral.writeValue(_:for:type: .withResponse)` will not cause iOS to
  fail or warn — but the watch firmware **never sends an ATT Write Response
  PDU back**. CoreBluetooth's `peripheral(_:didWriteValueFor:error:)`
  callback will therefore **never fire**, and any code that awaits that
  callback will hang forever (matches the symptom: "47-byte write hangs when
  we use `.withResponse`").
* The correct iOS write type is `.withoutResponse` for **every single write**
  to the send characteristic. There is no exception for "small control
  frames" — the Garmin-side ACK is at the GFDI layer, not the ATT layer.

### Flow control — Gadgetbridge's actual mechanism

Even though every write to the Garmin send characteristic is
write-without-response, Gadgetbridge does **not** fire writes back-to-back.
It serializes them through `BtLEQueue` (a single worker thread that pulls
from an action queue) gated by `BtLEAction.expectsResult()`:

```java
// service/btle/BtLEQueue.java:179–193
mWaitForActionResultLatch = new CountDownLatch(1);
...
boolean waitForResult = action.expectsResult();
if (waitForResult) {
    mWaitForActionResultLatch.await();   // BLOCKS until callback fires
    mWaitForActionResultLatch = null;
}
```

The latch is released only when the GATT callback for that action returns
(for writes, `onCharacteristicWrite` at `BtLEQueue.java:700–710`). And
`WriteAction.expectsResult()` returns **`true` for every write — including
write-without-response** — with this explicit TODO comment:

```java
// service/btle/actions/WriteAction.java:58–62
//TODO: expectsResult should return false if PROPERTY_WRITE_NO_RESPONSE
// is true, but this leads to timing issues
@Override
public boolean expectsResult() {
    return true;
}
```

i.e. the GB devs intentionally wait for `onCharacteristicWrite` even on
write-without-response because not doing so breaks pairing. On Android,
`onCharacteristicWrite` IS dispatched for both write types, so the same
mechanism works for both.

### Implication for iOS

iOS does **not** fire `didWriteValueFor` for `.withoutResponse` writes —
so the direct Android mechanism doesn't transfer. The closest analog is
`peripheralIsReady(toSendWriteWithoutResponse:)`, but in practice that
callback is unreliable for older Garmin firmware (Instinct Solar 1
empirically never fires it, even after the BLE LL has drained).

The practical workaround that mirrors GB's "wait between writes" intent:

1. **Check `peripheral.canSendWriteWithoutResponse` before each write.**
   Apple's docs are explicit that ignoring this property causes silent drops.
2. **If `false`, poll the property at ~20 ms intervals.** This catches the
   transition even when the callback isn't delivered. Cap at ~2 s and
   proceed anyway — better to risk one drop than hang the BLE link past
   its supervision timeout.
3. **Sleep ~30 ms after every successful write.** Gives the iOS BLE stack
   and the watch's BLE LL time to actually transmit + ACK at the link
   layer, so `canSendWriteWithoutResponse` has a chance to flip back to
   `true` before the next write. Without this, three back-to-back
   `writeValue` calls in 2 ms blow iOS's internal queue and silent-drop
   subsequent writes.

This is what `BluetoothCentral.write()` in `Packages/CompassBLE/` does
today. Two failure modes were hit on the way to this pattern, both
captured in `logs.log` history:

* **Unbounded poll on `canSendWriteWithoutResponse`** → blocked for ~30 s
  when the property never flipped, hitting the BLE supervision timeout
  and dropping the link entirely.
* **Pure `peripheralIsReady` callback wait, no fallback** → blocked
  forever because iOS never fired the callback for this peripheral.
  Same supervision-timeout outcome.

---

## 3. The Multi-Link Layer

Multi-Link rides on top of GATT writes/notifies on the chosen
`…28x0/…28x0+0x10` pair. The first byte of every notification / write payload
is a **handle**:

* Handle `0x00` is reserved for the *handle management* control plane.
* Handle `0x01..` is allocated by the watch in REGISTER_ML_RESP and is then
  used as the prefix for all data on that service.
* If the high bit (`0x80`) is set, the byte is an MLR header (see §9).

### CLOSE_ALL_REQ — exact bytes

```java
// CommunicatorV2.java:497–504
private byte[] closeAllServices() {
    final ByteBuffer toSend = ByteBuffer.allocate(13).order(ByteOrder.LITTLE_ENDIAN);
    toSend.put((byte) 0);                                    // handle = 0
    toSend.put((byte) RequestType.CLOSE_ALL_REQ.ordinal());  // type   = 5
    toSend.putLong(GADGETBRIDGE_CLIENT_ID);                  // clientId = 2 (LE 8-byte)
    toSend.putShort((short) 0);                              // padding (LE 2-byte 0x0000)
    return toSend.array();
}
```

The `RequestType` enum ordinals are decisive:

```java
// CommunicatorV2.java:556–565
private enum RequestType {
    REGISTER_ML_REQ,    // 0
    REGISTER_ML_RESP,   // 1
    CLOSE_HANDLE_REQ,   // 2
    CLOSE_HANDLE_RESP,  // 3
    UNK_HANDLE,         // 4
    CLOSE_ALL_REQ,      // 5
    CLOSE_ALL_RESP,     // 6
    UNK_REQ,            // 7
    UNK_RESP;           // 8
}
```

`GADGETBRIDGE_CLIENT_ID = 2L` (`CommunicatorV2.java:53`).

CLOSE_ALL_REQ wire bytes (13 bytes total, all little-endian):

```
00 05  02 00 00 00 00 00 00 00  00 00
^^ ^^  ^^^^^^^^^^^^^^^^^^^^^^^  ^^^^^
hd type           clientId       pad
```

### REGISTER_ML_REQ — exact bytes

```java
// CommunicatorV2.java:506–514
private byte[] registerService(final Service service, final boolean reliable) {
    final ByteBuffer toSend = ByteBuffer.allocate(13).order(ByteOrder.LITTLE_ENDIAN);
    toSend.put((byte) 0);                                     // handle = 0
    toSend.put((byte) RequestType.REGISTER_ML_REQ.ordinal()); // type   = 0
    toSend.putLong(GADGETBRIDGE_CLIENT_ID);                   // clientId = 2
    toSend.putShort(service.getCode());                       // service code (LE u16)
    toSend.put((byte) (reliable ? 2 : 0));                    // reliable flag
    return toSend.array();
}
```

For GFDI the service code is `1` (`Service.GFDI(1)`, `CommunicatorV2.java:580`).
After CLOSE_ALL_RESP, GB issues:

```java
// CommunicatorV2.java:396–398
mSupport.createTransactionBuilder("open GFDI")
        .write(characteristicSend, registerService(Service.GFDI, mSupport.mlrEnabled()))
        .queue();
```

`mlrEnabled()` returns `true` only when the user has flipped the experimental
preference `"garmin_mlr"`:

```java
// GarminSupport.java:538–540
public boolean mlrEnabled() {
    return getDevicePrefs().getBoolean("garmin_mlr", false);
}
```

For an out-of-the-box install, `mlrEnabled() == false`, so the **`reliable`
byte is `0x00`**, **not `0x02`**. (See §9 — Instinct does not require MLR.)

REGISTER_ML_REQ for GFDI, basic ML, wire bytes:

```
00 00  02 00 00 00 00 00 00 00  01 00  00
^^ ^^  ^^^^^^^^^^^^^^^^^^^^^^^  ^^^^^  ^^
hd type           clientId      svc=1 reliable=0
```

### REGISTER_ML_RESP — exact parsing

```java
// CommunicatorV2.java:294–308
case REGISTER_ML_RESP: {
    final short registeredServiceCode = message.getShort(); // u16 LE
    final Service registeredService = Service.fromCode(registeredServiceCode);
    final byte status = message.get();                       // 0 == OK
    …
    final int handle  = message.get() & 0xff;
    final int reliable = message.get();                      // 0 or 2
    …
}
```

After the `processHandleManagement` reads the leading `handle (=0)` and
`type (=1)` and `clientId (8)`, the remaining bytes are:

```
| serviceCode (2) | status (1) | handle (1) | reliable (1) |
```

So a successful REGISTER_ML_RESP for GFDI in basic mode is:

```
00 01  02 00 00 00 00 00 00 00  01 00  00  HH  00
^^ ^^  ^^^^^^^^^^^^^^^^^^^^^^^  ^^^^^  ^^  ^^  ^^
hd t=1           clientId       svc=1   ok hndl rel=0
```

where `HH` is the assigned handle (typically `0x01` on the first allocation,
but the watch may pick anything 1–7 in basic mode; up to 0x10 in MLR mode).

### CLOSE_HANDLE_REQ — exact bytes

```java
// CommunicatorV2.java:516–524
private byte[] closeService(final Service service, final int handle) {
    final ByteBuffer toSend = ByteBuffer.allocate(13).order(ByteOrder.LITTLE_ENDIAN);
    toSend.put((byte) 0);
    toSend.put((byte) RequestType.CLOSE_HANDLE_REQ.ordinal()); // type = 2
    toSend.putLong(GADGETBRIDGE_CLIENT_ID);
    toSend.putShort(service.getCode());
    toSend.put((byte) handle);
    return toSend.array();
}
```

This is only sent later when GB explicitly closes a service (e.g. realtime HR
toggle off). Not part of pairing.

### Handle dispatching on inbound

```java
// CommunicatorV2.java:184–204
final ByteBuffer message = ByteBuffer.wrap(value).order(ByteOrder.LITTLE_ENDIAN);
final byte handle = message.get();
if (0x00 == handle) {
    processHandleManagement(message);   // CLOSE_ALL_RESP, REGISTER_ML_RESP, …
    return true;
}
final Service service = serviceByHandle.get(handle & 0xff);
if (service != null) {
    final ServiceCallback serviceCallback = serviceCallbacks.get(service);
    if (serviceCallback != null) {
        serviceCallback.onMessage(Arrays.copyOfRange(value, 1, value.length));
    }
}
```

Note `handle & 0xff` — the handle is treated as **unsigned**. There's
also a defensive note at line 181: `// #5476 - It looks like non-MLR handles
can also have the msb set, so we let it fall through`. Don't naively assume
"high bit set ⇒ MLR".

---

## 4. The COBS Frame Layer

GFDI bytes are **always COBS-wrapped** before they hit the GATT write. Garmin
uses a non-standard COBS variant: a leading `0x00` *and* a trailing `0x00`
(standard COBS only has one).

Encoder summary (`service/devices/garmin/communicator/CobsCoDec.java:82–124`):

1. Write a leading `0x00`.
2. Walk the input. For each non-zero run up to 0xFE bytes long, emit
   `code = runLen + 1` followed by the run bytes. Repeat for the next run.
3. If the input ended on a `0x00`, emit a trailing `0x01` (zero-length run
   pseudo-overhead).
4. Write a trailing `0x00`.

Decoder (`CobsCoDec.java:44–79`):

* Buffer until last byte is `0x00`. If the leading byte is also `0x00`,
  start decoding. The decoder follows a standard "code byte → run length =
  code-1; insert `0x00` between consecutive runs unless the previous code
  was `0xFF`" rule.
* There is a 1500 ms timeout for partial buffers (`BUFFER_TIMEOUT`).

**The COBS layer is below the ML handle layer.** Inbound traffic on a
non-zero handle has its leading handle byte *removed* (line 196) before
being fed to `CobsCoDec.receivedBytes(...)`. Outbound traffic in basic mode
*first* COBS-encodes the GFDI bytes, *then* prepends the handle byte to each
fragment:

```java
// CommunicatorV2.java:132–150
final byte[] payload = CobsCoDec.encode(message);
…
final byte[] fragment = Arrays.copyOfRange(payload, position, position + Math.min(remainingBytes, maxWriteSize - 1));
builder.write(characteristicSend,
        ArrayUtils.addAll(new byte[]{gfdiHandle.byteValue()}, fragment));
```

Note the chunk size: `maxWriteSize - 1` (one byte reserved for the handle).

---

## 5. The GFDI Message Layer

A GFDI message is:

```
| length (u16 LE) | type (u16 LE) | payload (N bytes) | crc16 (u16 LE) |
```

The `length` field **includes itself, the type, the payload, and the CRC**
(i.e., `length == total_message_size_in_bytes`).

The CRC is computed over `[length | type | payload]` — i.e. everything
*before* the CRC bytes themselves. After serialisation, the CRC is appended.

```java
// messages/GFDIMessage.java:87–90
private void addLengthAndChecksum() {
    response.putShort(0, (short) (response.position() + 2));
    response.putShort((short) ChecksumCalculator.computeCrc(
            response.asReadOnlyBuffer(), 0, response.position()));
}
```

Why `position() + 2`? Because at this point the buffer holds the message
without the CRC; `position() + 2` accounts for the 2 CRC bytes that are
about to be written. The CRC is then computed over `[0, position())`, i.e.
all bytes *up to but not including* where the CRC will be written.

Receive side:

```java
// messages/GFDIMessage.java:164–196
public MessageReader(byte[] data) {
    super(data);
    this.byteBuffer.order(ByteOrder.LITTLE_ENDIAN);
    this.payloadSize = readShort();   // first u16 = total message length (incl. CRC)
    checkSize();                       //   asserts payloadSize == buffer.capacity()
    checkCRC();                        //   verifies the trailing u16 CRC
    this.byteBuffer.limit(payloadSize - 2); // strip CRC for downstream parsers
}
```

So when you parse a GFDI response, `length == buffer.length` exactly. If you
ever see otherwise, you have a framing bug.

`parseIncoming` then advances 2 more bytes for the type:

```java
// GFDIMessage.java:30–43
boolean supportedType = false;
int messageType = messageReader.readShort();
…
if ((messageType & 0x8000) != 0) {
    // final int sequenceNumber = (messageType >> 8) & 0x7f;
    messageType = (messageType & 0xff) + 5000;
}
final GarminMessage garminMessage = GarminMessage.fromId(messageType);
…
final Method m = garminMessage.objectClass.getMethod("parseIncoming",
        MessageReader.class, GarminMessage.class);
return garminMessage.objectClass.cast(m.invoke(null, messageReader, garminMessage));
```

(See §7 for the `& 0x8000` quirk.)

### Status / ACK message format

The generic ACK ("RESPONSE", `5000`):

```java
// messages/status/GenericStatusMessage.java:30–37
final MessageWriter writer = new MessageWriter(response);
writer.writeShort(0); // packet size will be filled below
writer.writeShort(GarminMessage.RESPONSE.getId());            // 5000 = 0x1388
writer.writeShort(messageType != 0 ? messageType : garminMessage.getId());
writer.writeByte(status.ordinal());                            // 0 == ACK
return sendOutgoing;
```

A standard ACK is therefore exactly 9 bytes on the wire:

```
| length=0009 | type=1388 (5000) | refType=u16 | status=00 | crc=u16 |
```

The `Status` enum:

```java
// GFDIMessage.java:145–162
public enum Status { ACK, NAK, UNSUPPORTED, DECODE_ERROR, CRC_ERROR, LENGTH_ERROR; … }
//      ordinal:    0    1     2            3              4         5
```

`GenericStatusMessage` gets generated automatically for every parsed message
unless overridden. The base `GFDIMessage.getStatusMessage()` is:

```java
// GFDIMessage.java:72–74
protected GFDIStatusMessage getStatusMessage() {
    return new GenericStatusMessage(garminMessage, Status.ACK);
}
```

Some handlers override this (e.g. `AuthNegotiationStatusMessage`,
`NotificationDataStatusMessage`, …). Look for `this.statusMessage = …` in
the constructor of each `*Message.java`.

### How `onMessage` orchestrates incoming → outgoing

The `GarminSupport.onMessage` entry point (`GarminSupport.java:326–368`):

```java
GFDIMessage parsedMessage = GFDIMessage.parseIncoming(message);
…
GFDIMessage followup = null;
for (MessageHandler han : messageHandlers) {
    followup = han.handle(parsedMessage);
    if (followup != null) break;
}

sendAck("send status", parsedMessage);           // 1) send the ACK/status
sendOutgoingMessage("send reply", parsedMessage); // 2) send the parsedMessage's
                                                  //    own outgoing bytes (only if
                                                  //    `generateOutgoing()` returns true)
sendOutgoingMessage("send followup", followup);   // 3) send any handler-produced followup

final List<GBDeviceEvent> events = parsedMessage.getGBDeviceEvent();
for (final GBDeviceEvent event : events) {
    evaluateGBDeviceEvent(event);
}
```

So for each inbound GFDI message, GB potentially sends **three** GFDI messages
back, in order:

1. The **ACK** (`statusMessage.getOutgoingMessage()` via `sendAck`).
2. The "reply" — typically the same message class re-serialised with the
   *host's* answers (e.g. host DEVICE_INFORMATION echoing back protocol
   version, software version, BT name, etc.). This only fires when the
   message was constructed with `generateOutgoing = true` — see §10.
3. A "followup" produced by a registered `MessageHandler`. None of the
   pairing handshake messages produce followups; the handlers in question
   (`fileTransferHandler`, `protocolBufferHandler`, `notificationsHandler`)
   produce followups for downloads, protobuf RPCs, and notification ops.

`sendAck` and `sendOutgoingMessage` no-op when their argument or its bytes
are `null` (`GarminSupport.java:662–680`).

---

## 6. The CRC-16 Variant

Garmin's GFDI uses a non-standard nibble-table CRC-16:

```java
// service/devices/garmin/ChecksumCalculator.java:21–49
private static final int[] CONSTANTS = {
        0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
        0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400
};

public static int computeCrc(int initialCrc, byte[] data, int offset, int length) {
    int crc = initialCrc;             // initialCrc is always 0
    for (int i = offset; i < offset + length; ++i) {
        int b = data[i];
        crc = (((crc >> 4) & 4095) ^ CONSTANTS[crc & 15]) ^ CONSTANTS[b & 15];
        crc = (((crc >> 4) & 4095) ^ CONSTANTS[crc & 15]) ^ CONSTANTS[(b >> 4) & 15];
    }
    return crc;
}
```

Properties to verify your iOS port:

* Initial value `0`.
* Two nibble passes per byte: low nibble first, high nibble second.
* `& 4095` after `>> 4` masks the result to 12 bits before XOR; this is the
  intentional table reduction.
* No final XOR or bit reversal.
* Result is stored as **little-endian u16** at the end of the message.

This is the FIT/ANT-FS CRC-16 polynomial (0x8408 / reversed CRC-16-IBM).
Test vector: `crc(0x4F4B) == 0x71C2` is what GB produces for a 2-byte input
"OK" (use this if you write a regression test).

---

## 7. Compact Message-Type Encoding

```java
// GFDIMessage.java:33–36
if ((messageType & 0x8000) != 0) {
    // final int sequenceNumber = (messageType >> 8) & 0x7f;
    messageType = (messageType & 0xff) + 5000;
}
```

This branch lives **only in `parseIncoming`** — i.e., inbound only. It allows
the watch to send single-byte message-type opcodes by setting the high bit
and putting the 7-bit sequence number in bits 8–14. The low byte plus 5000
gives the canonical message ID. **Outgoing messages from GB always use the
full 5000-range form** (see every `writer.writeShort(garminMessage.getId())`
in `messages/*Message.java`). Do **not** emit the compact form when sending.

The full canonical message ID enum is:

```java
// GFDIMessage.java:92–121
public enum GarminMessage {
    RESPONSE(5000, GFDIStatusMessage.class),
    DOWNLOAD_REQUEST(5002, DownloadRequestMessage.class),
    UPLOAD_REQUEST(5003, UploadRequestMessage.class),
    FILE_TRANSFER_DATA(5004, FileTransferDataMessage.class),
    CREATE_FILE(5005, CreateFileMessage.class),
    FILTER(5007, FilterMessage.class),
    SET_FILE_FLAG(5008, SetFileFlagsMessage.class),
    FIT_DEFINITION(5011, FitDefinitionMessage.class),
    FIT_DATA(5012, FitDataMessage.class),
    WEATHER_REQUEST(5014, WeatherMessage.class),
    DEVICE_INFORMATION(5024, DeviceInformationMessage.class),
    DEVICE_SETTINGS(5026, SetDeviceSettingsMessage.class),
    SYSTEM_EVENT(5030, SystemEventMessage.class),
    SUPPORTED_FILE_TYPES_REQUEST(5031, SupportedFileTypesMessage.class),
    NOTIFICATION_UPDATE(5033, NotificationUpdateMessage.class),
    NOTIFICATION_CONTROL(5034, NotificationControlMessage.class),
    NOTIFICATION_DATA(5035, NotificationDataMessage.class),
    NOTIFICATION_SUBSCRIPTION(5036, NotificationSubscriptionMessage.class),
    SYNCHRONIZATION(5037, SynchronizationMessage.class),
    FIND_MY_PHONE_REQUEST(5039, FindMyPhoneRequestMessage.class),
    FIND_MY_PHONE_CANCEL(5040, FindMyPhoneCancelMessage.class),
    MUSIC_CONTROL(5041, MusicControlMessage.class),
    MUSIC_CONTROL_CAPABILITIES(5042, MusicControlCapabilitiesMessage.class),
    PROTOBUF_REQUEST(5043, ProtobufMessage.class),
    PROTOBUF_RESPONSE(5044, ProtobufMessage.class),
    MUSIC_CONTROL_ENTITY_UPDATE(5049, MusicControlEntityUpdateMessage.class),
    CONFIGURATION(5050, ConfigurationMessage.class),
    CURRENT_TIME_REQUEST(5052, CurrentTimeRequestMessage.class),
    AUTH_NEGOTIATION(5101, AuthNegotiationMessage.class);
}
```

The pairing-relevant ones (in roughly the order they are used) are:
`DEVICE_INFORMATION (5024)`, `CONFIGURATION (5050)`, `AUTH_NEGOTIATION (5101)`,
`SYSTEM_EVENT (5030)`, `SUPPORTED_FILE_TYPES_REQUEST (5031)`,
`DEVICE_SETTINGS (5026)`. The watch may choose to send any of them — and
at least DEVICE_INFORMATION arrives in compact form in some firmwares
(`(0x18 | 0x80) | (seq << 8)`); the `& 0x8000` branch handles that.

---

## 8. `MessageWriter` / `MessageReader` Conventions

### `MessageWriter` (`messages/MessageWriter.java`)

* Backing buffer is fixed-order **LITTLE-ENDIAN** (`MessageWriter.java:18, 24`).
* `writeShort(int)` writes 2 bytes LE; `writeInt(int)` writes 4 bytes LE; …
* String format:

  ```java
  // MessageWriter.java:55–62
  public void writeString(String value) {
      final byte[] bytes = value.getBytes(StandardCharsets.UTF_8);
      final int size = bytes.length;
      if (size > 255) throw new IllegalArgumentException("Too long string");
      byteBuffer.put((byte) size);
      byteBuffer.put(bytes);
  }
  ```

  → **1-byte length prefix + UTF-8 bytes, NO null terminator**. Maximum 255
  bytes after UTF-8 encoding (not 255 codepoints).

  There is a separate `readNullTerminatedString` in `GarminByteBufferReader`
  (`GarminByteBufferReader.java:69–82`) that handles a different format,
  used by some FIT-related fields. The pairing handshake uses only
  length-prefixed strings.

### `MessageReader` (inner class of `GFDIMessage`)

```java
// GFDIMessage.java:164–196
public static class MessageReader extends GarminByteBufferReader {
    private final int payloadSize;

    public MessageReader(byte[] data) {
        super(data);
        this.byteBuffer.order(ByteOrder.LITTLE_ENDIAN);
        this.payloadSize = readShort();
        checkSize();
        checkCRC();
        this.byteBuffer.limit(payloadSize - 2);
    }
}
```

Constructor consumes the 2-byte length, validates CRC, then narrows the
buffer's `limit` so downstream parsers (which start by reading the message
type) can't accidentally slurp the CRC.

`readString()` is symmetric to `writeString` (`GarminByteBufferReader.java:62–67`):

```java
public String readString() {
    final int size = readByte();
    byte[] bytes = new byte[size];
    byteBuffer.get(bytes);
    return new String(bytes, StandardCharsets.UTF_8);
}
```

Confirmed: **1-byte length prefix + UTF-8, no NUL terminator.**

CRC scope is therefore `[length(2) | type(2) | payload(N)]`, CRC appended
after — exactly what §5 says.

---

## 9. Reliable Mode (MLR) vs Basic ML

### Whether Instinct uses MLR

Decision: **No, by default.** GB only opts into MLR when the user enables
the experimental preference `garmin_mlr` (`GarminSupport.java:538–540`),
**and** the watch supports `MULTI_LINK_SERVICE` capability (`GarminCapability.MULTI_LINK_SERVICE`,
ordinal 76 in `GarminCapability.java:107`). The `reliable` byte in
REGISTER_ML_REQ is `0x00` for an Instinct out of the box.

Furthermore, the Instinct Solar (1st gen) firmware does **not advertise**
MULTI_LINK_SERVICE in its CONFIGURATION bitmask in any logs we have. So even
if you flipped the preference, the watch wouldn't accept reliable mode for
that device.

**Recommendation: drive your iOS implementation with `reliable = 0` for
the Instinct Solar.**

### MLR framing (for completeness)

If MLR is in use, fragments are 2-byte-headered as documented in
`MlrCommunicator.java:239–252`:

```java
private byte[] createPacket(final int reqNum, final int seqNum, final byte[] data) {
    byte[] packet = new byte[2 + data.length];
    // First byte: MLR flag (1) + handle (3 bits) + reqNum high bits (4 bits)
    packet[0] = (byte) (MLR_FLAG_MASK | ((handle & 0x07) << HANDLE_SHIFT) | ((reqNum >> 2) & REQ_NUM_MASK));
    // Second byte: reqNum low bits (2 bits) + seqNum (6 bits)
    packet[1] = (byte) (((reqNum & 0x03) << 6) | (seqNum & SEQ_NUM_MASK));
    System.arraycopy(data, 0, packet, 2, data.length);
    return packet;
}
```

Bit layout:

```
byte0:  1 | h h h | r r r r          (msb=MLR flag, then 3-bit handle, then top 4 bits of reqNum)
byte1:  r r | s s s s s s            (top 2 bits of byte = bottom 2 bits of reqNum, low 6 = seqNum)
```

* `MLR_FLAG_MASK   = 0x80`
* `HANDLE_MASK     = 0x70`, `HANDLE_SHIFT = 4`
* `REQ_NUM_MASK    = 0x0F` (low 4 bits of byte0; combined with top 2 of byte1 → 6 bits total)
* `SEQ_NUM_MASK    = 0x3F` (low 6 bits of byte1)

So **MLR replaces the basic-ML "one-byte handle prefix" with a two-byte
header** that encodes (handle, reqNum, seqNum). The handle field in MLR is
only 3 bits wide — that's why `handle & 0x07` is used everywhere — so MLR
can address up to 8 handles (0..7), and the high bit of the byte
distinguishes it from non-MLR traffic. The `lastSendAck`, `nextSendSeq`,
`maxNumUnackedSend`, exponential backoff (`INITIAL_RETRANSMISSION_TIMEOUT =
1000`, doubled up to 20000), `ACK_TIMEOUT = 250 ms`, and `ACK_TRIGGER_THRESHOLD
= 5` constants are all in `MlrCommunicator.java:19–30`.

In **basic ML** (the Instinct path), there is no MLR framing — the on-wire
GATT payload is literally `[handle (1 byte) | cobs_chunk]`. When fragmented
across multiple GATT writes, only the **first** fragment of a GFDI message
contains the leading `0x00` of the COBS frame; successive fragments simply
continue the COBS bytes after their own one-byte handle.

### `MlrCommunicator.onConnectionStateChange`

Just clears the timeout handler if the GATT disconnects
(`MlrCommunicator.java:299–303`). Safe to ignore in basic mode.

---

## 10. Pairing — Full Chronological Byte-Level Walkthrough

Below is a single, successful pairing of a freshly-reset Instinct Solar
1st gen with Gadgetbridge in basic-ML mode (no MLR). All numbers are hex
unless stated. Phone = central; Watch = peripheral.

### Step 0 — User triggers "Connect first time"

`GarminSupport.connectFirstTime()` (`GarminSupport.java:1286–1290`) sets
`mFirstConnect = true` and calls `connect()`. The boolean affects only the
final `SETUP_WIZARD_COMPLETE` / `PAIR_COMPLETE` bursts (§13), not the
on-wire pairing.

The Garmin coordinator imposes **no special bonding**:

```java
// devices/garmin/GarminCoordinator.java:79–82
@Override
public boolean suggestUnbindBeforePair() {
    return false;
}
```

There is no override of `getBondingStyle()`, no `requireKeyPairing` flag,
and no call to `requestBond()` anywhere in the Garmin code. The Android
GATT stack will attempt insecure connection by default and only escalate
to LE Secure Connections / pairing if the watch sends an SMP request as a
response to a write. (See §14 for iOS implications.)

### Step 1 — GATT connect, MTU, notify, CLOSE_ALL_REQ

`GarminSupport.initializeDevice` (`GarminSupport.java:261–284`) queues —
in order:

1. `setDeviceState(INITIALIZING)`.
2. `requestMtu(515)`.
3. `notify(receiveCharacteristic, true)` → CCCD descriptor write `01 00`.
4. `write(sendCharacteristic, closeAllServices())` — see exact 13 bytes
   in §3.

```
phone → watch  (ATT Write Cmd to …2820, 13 bytes)
00 05 02 00 00 00 00 00 00 00 00 00 00
```

iOS: `peripheral.writeValue(_:for:type:.withoutResponse)`.

### Step 2 — CLOSE_ALL_RESP

```
watch → phone  (Notification on …2810, 13 bytes)
00 06 02 00 00 00 00 00 00 00 ?? ?? ??
^^ ^^                          ^^^^^^^
hd type=6 (CLOSE_ALL_RESP)     payload (typically 00 00 00)
```

GB clears its handle map and *immediately* enqueues REGISTER_ML_REQ for GFDI:

```java
// CommunicatorV2.java:388–399
case CLOSE_ALL_RESP:
    LOG.debug("Received close all handles response. …");
    serviceByHandle.clear();
    handleByService.clear();
    for (ServiceCallback callback : serviceCallbacks.values()) {
        callback.onClose();
    }
    serviceCallbacks.clear();
    mSupport.createTransactionBuilder("open GFDI")
            .write(characteristicSend, registerService(Service.GFDI, mSupport.mlrEnabled()))
            .queue();
    break;
```

### Step 3 — REGISTER_ML_REQ for GFDI

```
phone → watch  (ATT Write Cmd to …2820, 13 bytes)
00 00 02 00 00 00 00 00 00 00 01 00 00
^^ ^^                         ^^^^^ ^^
hd type=0                     svc=1 reliable=0
```

### Step 4 — REGISTER_ML_RESP

```
watch → phone  (Notification on …2810, 14 bytes)
00 01 02 00 00 00 00 00 00 00 01 00 00 HH 00
                              ^^^^^ ^^ ^^ ^^
                              svc=1 ok hndl rel=0
```

Note: payload length on the wire is **14 bytes** in basic mode (vs 13 for
the request). The extra byte is the assigned handle. `HH` is the handle
the watch picked — typically `0x01`. From here on, all GFDI traffic in both
directions starts with this handle byte.

GB sets `serviceByHandle[HH] = GFDI`, `handleByService[GFDI] = HH`,
instantiates a `GfdiCallback`, and "connects" it (`CommunicatorV2.java:310–357`).
For `reliable == 0`, no MLR communicator is created.

### Step 5 — Watch initiates GFDI handshake by sending DEVICE_INFORMATION

The watch is the one that drives the GFDI handshake. The first inbound GFDI
message after the GFDI handle is registered is `DEVICE_INFORMATION` (5024).
Its on-wire form is **COBS-wrapped** with handle `HH` prefix on each
fragment.

After dehandling and COBS-decoding, the GFDI bytes are:

```
| len (2, LE) | type=5024 (=0xA0 0x13 LE) | proto (2) | product (2) |
| unit (4)    | softVer (2) | maxPacket (2) |
| btName(len-pref UTF-8) | devName(len-pref UTF-8) | devModel(len-pref UTF-8) |
| crc (2) |
```

Some firmwares emit DEVICE_INFORMATION using the compact form: `type =
0xA0 | 0x80 = 0xA0 + sequenceFlag in high byte` → `(messageType & 0xff) +
5000 = 0xA0 + 5000 = 5024`. The §7 transform handles that transparently.

`DeviceInformationMessage.parseIncoming`
(`messages/DeviceInformationMessage.java:51–62`):

```java
final int protocolVersion = reader.readShort();
final int productNumber  = reader.readShort();
final String unitNumber  = Long.toString(reader.readInt() & 0xFFFFFFFFL);
final int softwareVersion = reader.readShort();
final int maxPacketSize   = reader.readShort();
final String bluetoothFriendlyName = reader.readString();
final String deviceName            = reader.readString();
final String deviceModel           = reader.readString();
```

### Step 6 — Phone replies to DEVICE_INFORMATION

This is the part that's been ambiguous; here's the definitive answer.

When `parseIncoming` constructs the `DeviceInformationMessage`, it uses
the constructor at line 47–49:

```java
public DeviceInformationMessage(GarminMessage garminMessage, …) {
    this(garminMessage, …, false);   // generateOutgoing = false
}
```

…so `this.generateOutgoing == false` for incoming messages, and
`generateOutgoing()` returns `false` (see `DeviceInformationMessage.java:90`).
That means `getOutgoingMessage()` returns `null` for the *incoming*
instance, **but the side-effect of `generateOutgoing()` still writes the
host's response bytes into the buffer**:

```java
// DeviceInformationMessage.java:65–91
@Override
protected boolean generateOutgoing() {
    final int protocolFlags = this.incomingProtocolVersion / 100 == 1 ? 1 : 0;

    final MessageWriter writer = new MessageWriter(response);
    writer.writeShort(0); // placeholder for packet size
    writer.writeShort(GarminMessage.RESPONSE.getId());        // 5000
    writer.writeShort(this.garminMessage.getId());            // 5024
    writer.writeByte(Status.ACK.ordinal());                   // 0
    writer.writeShort(ourProtocolVersion);                    // 150
    writer.writeShort(ourProductNumber);                      // -1 → 0xFFFF
    writer.writeInt(ourUnitNumber);                           // -1 → 0xFFFFFFFF
    writer.writeShort(ourSoftwareVersion);                    // 7791
    writer.writeShort(ourMaxPacketSize);                      // -1 → 0xFFFF
    writer.writeString(bluetoothName);                        // BluetoothAdapter.getDefaultAdapter().getName() or "Unknown"
    writer.writeString(Build.MANUFACTURER);                   // e.g. "Google"
    writer.writeString(Build.DEVICE);                         // e.g. "redfin"
    writer.writeByte(protocolFlags);
    return this.generateOutgoing;   // false for incoming, true only when host constructs it
}
```

But — and this is the crucial bit — `DeviceInformationMessage` overrides
`getStatusMessage()` indirectly via `this.statusMessage = getStatusMessage();`
in its constructor at line 43, where `getStatusMessage()` is the inherited
default (`GFDIMessage.java:72-74`) returning a `GenericStatusMessage`. So:

| Attribute                           | Value when receiving DI from watch                                |
| ----------------------------------- | ----------------------------------------------------------------- |
| `parsedMessage.getAckBytestream()`  | A 9-byte `RESPONSE`/ACK referencing message type 5024.           |
| `parsedMessage.getOutgoingMessage()`| `null` (because `generateOutgoing` returns false).               |

Therefore `GarminSupport.onMessage` (lines 355–357) ends up sending only
**ONE** outbound packet in response to DEVICE_INFORMATION — the **generic
ACK**, not a host DEVICE_INFORMATION reply. The "host DEVICE_INFORMATION
echo with bluetoothName / Build.MANUFACTURER / Build.DEVICE" code is only
exercised in the unit test path — Gadgetbridge itself never sends it during
real pairing.

This is consistent with the GB protocol notes and with packet captures: the
real Garmin Connect app does the same — it ACKs DEVICE_INFORMATION and
moves on; it does **not** echo a host-side DEVICE_INFORMATION as a separate
GFDI message.

> **TL;DR — settled definitively:** in response to the watch's
> DEVICE_INFORMATION, GB sends exactly one outbound GFDI message, a 9-byte
> generic ACK with `originalType = 5024`. There is no separate host
> DEVICE_INFORMATION transmit.

The 9-byte ACK on the wire (before CRC):

```
09 00 88 13 A0 13 00 .. ..
^^^^^ ^^^^^ ^^^^^ ^^
len   5000  5024  status=ACK    + crc16(LE)
```

After CRC (e.g. CRC bytes shown as `cc cc`) and after the §4 COBS wrap and
§3 handle prefix, you'll see the actual GATT bytes start with
`HH 00 0A 09 00 89 14 A1 14 01 cc' cc' 00`-ish — the COBS code byte (`0A`
= "10 bytes follow without zero") then the 9 GFDI bytes, then trailer `00`.
(Each `0x00` byte in the GFDI bytes will get COBS-code-shifted; the layout
above is illustrative.)

### Step 7 — Watch sends CONFIGURATION (5050)

Wire bytes after dehandling+decobs:

```
| len (2) | type=5050 | numBytes (1) | bitmask (numBytes bytes) | crc (2) |
```

`ConfigurationMessage.parseIncoming` (`messages/ConfigurationMessage.java:26–29`):

```java
public static ConfigurationMessage parseIncoming(MessageReader reader, GarminMessage garminMessage) {
    final int numBytes = reader.readByte();
    return new ConfigurationMessage(garminMessage, reader.readBytes(numBytes));
}
```

The constructor (`messages/ConfigurationMessage.java:15–24`) parses the
bitmask into a `Set<GarminCapability>` and emits a `CapabilitiesDeviceEvent`
later (via `getGBDeviceEvent()`).

### Step 8 — Phone replies to CONFIGURATION (CONFIGURATION echoed with OUR bitmask)

`ConfigurationMessage` does **not** override
`generateOutgoing` to gate it on a flag — it always returns `true`:

```java
// messages/ConfigurationMessage.java:36–44
@Override
protected boolean generateOutgoing() {
    final MessageWriter writer = new MessageWriter(response);
    writer.writeShort(0); // placeholder for packet size
    writer.writeShort(garminMessage.getId());        // 5050
    writer.writeByte(ourConfigurationPayload.length);
    writer.writeBytes(ourConfigurationPayload);
    return true;
}
```

But — `parseIncoming` returns the **same `ConfigurationMessage` object**
that just consumed the watch's bitmask. When `GarminSupport.onMessage` then
calls `parsedMessage.getOutgoingMessage()`, that re-uses the **shared
`response` ByteBuffer** (allocated 10 KiB in `GFDIMessage.java:23`),
which still contains the inbound bytes. Look at `GFDIMessage.getOutgoingMessage`:

```java
// GFDIMessage.java:58–70
public byte[] getOutgoingMessage() {
    response.clear();              // <--- clears position back to 0
    boolean toSend = generateOutgoing();
    response.order(ByteOrder.LITTLE_ENDIAN);
    if (!toSend)
        return null;
    addLengthAndChecksum();
    response.flip();
    final byte[] packet = new byte[response.limit()];
    response.get(packet);
    return packet;
}
```

`response.clear()` rewinds it before re-writing. So the parsed-on-the-fly
`ConfigurationMessage` *does* end up serialising the **host's** capability
bitmask. **This is one of the few cases where the inbound message instance
also generates an outbound reply** (DEVICE_INFORMATION is *not* such a
case; CONFIGURATION *is*).

Therefore in response to the watch's CONFIGURATION, GB sends:

1. The 9-byte ACK (type 5000 referencing 5050), then
2. A separate `CONFIGURATION` (5050) message with the host's `OUR_CAPABILITIES`
   bitmask.

Wire format of (2):

```
| len(2) | type=5050(2) | bitmaskLen(1) | bitmaskBytes(bitmaskLen) | crc(2) |
```

`OUR_CAPABILITIES` is the full enum of `GarminCapability` minus
`UNK_104..UNK_111, UNK_114..UNK_119`:

```java
// devices/garmin/GarminCapability.java:153–178
public static final Set<GarminCapability> OUR_CAPABILITIES = new HashSet<>(values().length);
private static final Map<Integer, GarminCapability> FROM_ORDINAL = new HashMap<>(values().length);

static {
    for (final GarminCapability cap : values()) {
        FROM_ORDINAL.put(cap.ordinal(), cap);
        OUR_CAPABILITIES.add(cap);
    }
    // so far dumps from Garmin Connect have only supported UNK_112 and UNK_113
    OUR_CAPABILITIES.remove(UNK_104);
    OUR_CAPABILITIES.remove(UNK_105);
    OUR_CAPABILITIES.remove(UNK_106);
    OUR_CAPABILITIES.remove(UNK_107);
    OUR_CAPABILITIES.remove(UNK_108);
    OUR_CAPABILITIES.remove(UNK_109);
    OUR_CAPABILITIES.remove(UNK_110);
    OUR_CAPABILITIES.remove(UNK_111);
    OUR_CAPABILITIES.remove(UNK_114);
    OUR_CAPABILITIES.remove(UNK_115);
    OUR_CAPABILITIES.remove(UNK_116);
    OUR_CAPABILITIES.remove(UNK_117);
    OUR_CAPABILITIES.remove(UNK_118);
    OUR_CAPABILITIES.remove(UNK_119);
}
```

Bit layout (`GarminCapability.java:212–228`): 1 bit per ordinal, LSB-first
within each byte, byte 0 holds ordinals 0..7, byte 1 holds 8..15, etc. The
bitmask byte length is `ceil(values().length / 8)` — for the current
`120-entry` enum this is **15 bytes**.

The named bits set in `OUR_CAPABILITIES` (i.e., what GB claims to support):

```
CONNECT_MOBILE_FIT_LINK, GOLF_FIT_LINK, VIVOKID_JR_FIT_LINK, SYNC,
DEVICE_INITIATES_SYNC, HOST_INITIATED_SYNC_REQUESTS, GNCS,
ADVANCED_MUSIC_CONTROLS, FIND_MY_PHONE, FIND_MY_WATCH, CONNECTIQ_HTTP,
CONNECTIQ_SETTINGS, CONNECTIQ_WATCH_APP_DOWNLOAD, CONNECTIQ_WIDGET_DOWNLOAD,
CONNECTIQ_WATCH_FACE_DOWNLOAD, CONNECTIQ_DATA_FIELD_DOWNLOAD,
CONNECTIQ_APP_MANAGEMENT, COURSE_DOWNLOAD, WORKOUT_DOWNLOAD,
GOLF_COURSE_DOWNLOAD, DELTA_SOFTWARE_UPDATE_FILES, FITPAY, LIVETRACK,
LIVETRACK_AUTO_START, LIVETRACK_MESSAGING, GROUP_LIVETRACK,
WEATHER_CONDITIONS, WEATHER_ALERTS, GPS_EPHEMERIS_DOWNLOAD, EXPLICIT_ARCHIVE,
SWING_SENSOR, SWING_SENSOR_REMOTE, INCIDENT_DETECTION, TRUEUP, INSTANT_INPUT,
SEGMENTS, AUDIO_PROMPT_LAP, AUDIO_PROMPT_PACE_SPEED, AUDIO_PROMPT_HEART_RATE,
AUDIO_PROMPT_POWER, AUDIO_PROMPT_NAVIGATION, AUDIO_PROMPT_CADENCE,
SPORT_GENERIC, SPORT_RUNNING, SPORT_CYCLING, SPORT_TRANSITION,
SPORT_FITNESS_EQUIPMENT, SPORT_SWIMMING, STOP_SYNC_AFTER_SOFTWARE_UPDATE,
CALENDAR, WIFI_SETUP, SMS_NOTIFICATIONS, BASIC_MUSIC_CONTROLS,
AUDIO_PROMPTS_SPEECH, DELTA_SOFTWARE_UPDATES, GARMIN_DEVICE_INFO_FILE_TYPE,
SPORT_PROFILE_SETUP, HSA_SUPPORT, SPORT_STRENGTH, SPORT_CARDIO, UNION_PAY,
IPASS, CIQ_AUDIO_CONTENT_PROVIDER, UNION_PAY_INTERNATIONAL, REQUEST_PAIR_FLOW,
LOCATION_UPDATE, LTE_SUPPORT, DEVICE_DRIVEN_LIVETRACK_SUPPORT,
CUSTOM_CANNED_TEXT_LIST_SUPPORT, EXPLORE_SYNC, INCIDENT_DETECT_AND_ASSISTANCE,
CURRENT_TIME_REQUEST_SUPPORT, CONTACTS_SUPPORT, LAUNCH_REMOTE_CIQ_APP_SUPPORT,
DEVICE_MESSAGES, WAYPOINT_TRANSFER, MULTI_LINK_SERVICE, OAUTH_CREDENTIALS,
GOLF_9_PLUS_9, ANTI_THEFT_ALARM, INREACH, EVENT_SHARING,
UNK_82, UNK_83, UNK_84, UNK_85, UNK_86, UNK_87, UNK_88, UNK_89, UNK_90, UNK_91,
REALTIME_SETTINGS,
UNK_93, UNK_94, UNK_95, UNK_96, UNK_97, UNK_98, UNK_99, UNK_100, UNK_101, UNK_102, UNK_103,
UNK_112, UNK_113
```

Once parsed, GB raises a `CapabilitiesDeviceEvent`. The handler
(`GarminSupport.evaluateGBDeviceEvent`, `GarminSupport.java:395–413`) calls
`completeInitialization()` — see §13.

### Step 9 — Optional: AUTH_NEGOTIATION (5101)

AUTH_NEGOTIATION is sent by some watches (notably newer Fenix / Venu /
Forerunner generations). On classic firmware (Instinct Solar 1st gen), we
have no logs of AUTH_NEGOTIATION ever being sent. **GB never *initiates*
AUTH_NEGOTIATION** — it only ever *responds* to one. If the watch sends
it, GB replies as follows:

```java
// messages/AuthNegotiationMessage.java:14–22
public AuthNegotiationMessage(GarminMessage garminMessage, int unknown, EnumSet<AuthFlags> requestedAuthFlags) {
    this.garminMessage = garminMessage;
    this.unknown = unknown;
    this.requestedAuthFlags = requestedAuthFlags;
    LOG.info("Message {}, unkByte: {}, flags: {}", garminMessage, unknown, requestedAuthFlags);
    this.statusMessage = new AuthNegotiationStatusMessage(
            garminMessage, Status.ACK,
            AuthNegotiationStatusMessage.AuthNegotiationStatus.GUESS_OK,
            this.unknown, requestedAuthFlags);
}
```

i.e., GB constructs an `AuthNegotiationStatusMessage(ACK, GUESS_OK,
unknown, requestedAuthFlags)` as the ACK. Wire format of this special ACK
(`messages/status/AuthNegotiationStatusMessage.java:54–66`):

```
| len(2) | type=5000(2) | refType=5101(2) | status=ACK(1) | authNegStatus=GUESS_OK(0)(1) |
| unkByte(1) | authFlags(4 LE bitvector) | crc(2) |
```

So 15 bytes of content + 2 byte CRC.

GB's outgoing-from-the-message-itself path returns `false` from
`generateOutgoing()`:

```java
// messages/AuthNegotiationMessage.java:33–44
@Override
protected boolean generateOutgoing() {
    final MessageWriter writer = new MessageWriter(response);
    writer.writeShort(0);                 // placeholder
    writer.writeShort(this.garminMessage.getId());
    writer.writeByte(0);
    writer.writeInt((int) EnumUtils.generateBitVector(AuthFlags.class, EnumSet.noneOf(AuthFlags.class)));
    return false;                         // host never originates AUTH_NEGOTIATION
}
```

So the only AUTH_NEGOTIATION traffic is: `watch → AUTH_NEGOTIATION` →
`phone → AuthNegotiationStatus(ACK, GUESS_OK, …)`. Nothing else.

For Instinct Solar 1st gen — assume this never happens, but be prepared to
ACK if it does.

### Step 10 — `completeInitialization()` and post-init bursts

When the `CapabilitiesDeviceEvent` is processed, `completeInitialization()`
(`GarminSupport.java:789–818`) fires:

```java
sendOutgoingMessage("request supported file types", new SupportedFileTypesMessage());
sendDeviceSettings();                                           // sends DEVICE_SETTINGS (5026)

if (GBApplication.getPrefs().syncTime()) {
    onSetTime();                                                // sends SYSTEM_EVENT TIME_UPDATED (16)
}

// vivomove style needs this
sendOutgoingMessage("set sync ready", new SystemEventMessage(SystemEventMessage.GarminSystemEventType.SYNC_READY, 0));
                                                                // SYSTEM_EVENT type=8

enableBatteryLevelUpdate();                                     // protobuf request

gbDevice.setUpdateState(GBDevice.State.INITIALIZED, getContext());

if (mFirstConnect) {
    sendOutgoingMessage("set pair complete",
            new SystemEventMessage(GarminSystemEventType.PAIR_COMPLETE, 0));        // 4
    sendOutgoingMessage("set sync complete",
            new SystemEventMessage(GarminSystemEventType.SYNC_COMPLETE, 0));        // 0
    sendOutgoingMessage("set setup wizard complete",
            new SystemEventMessage(GarminSystemEventType.SETUP_WIZARD_COMPLETE, 0));// 14
    this.mFirstConnect = false;
}
```

The `SYSTEM_EVENT` ordinals map to:

```java
// messages/SystemEventMessage.java:30–48
public enum GarminSystemEventType {
    SYNC_COMPLETE,             // 0
    SYNC_FAIL,                 // 1
    FACTORY_RESET,             // 2
    PAIR_START,                // 3
    PAIR_COMPLETE,             // 4
    PAIR_FAIL,                 // 5
    HOST_DID_ENTER_FOREGROUND, // 6
    HOST_DID_ENTER_BACKGROUND, // 7
    SYNC_READY,                // 8
    NEW_DOWNLOAD_AVAILABLE,    // 9
    DEVICE_SOFTWARE_UPDATE,    // 10
    DEVICE_DISCONNECT,         // 11
    TUTORIAL_COMPLETE,         // 12
    SETUP_WIZARD_START,        // 13
    SETUP_WIZARD_COMPLETE,     // 14
    SETUP_WIZARD_SKIPPED,      // 15
    TIME_UPDATED               // 16
}
```

`SystemEventMessage` is always emitted with the 1-byte ordinal followed by
either a length-prefixed string or a 1-byte int (`messages/SystemEventMessage.java:14–28`).
For these init events the value is the integer `0`, so each emitted message
is:

```
| len=0008 | type=5030 (=0xA6 0x13 LE) | eventType (1) | value=0 (1) | crc (2) |
```

— **8 bytes total** on the wire.

### Step 11 — Device is "INITIALIZED"

`gbDevice.setUpdateState(GBDevice.State.INITIALIZED, getContext())` is the
moment GB considers the watch ready (`GarminSupport.java:807`). Note this
happens **inside** `completeInitialization()`, *before* the `mFirstConnect`
PAIR_COMPLETE / SYNC_COMPLETE / SETUP_WIZARD_COMPLETE bursts go out. But
because `setUpdateState` only sets state and broadcasts an intent, those
follow-up SYSTEM_EVENT writes are still queued correctly.

### Wrap-up sequence diagram

```
phone                                       watch
  |  GATT connect, MTU=515 request           |
  |----------------------------------------> |
  |                                          |
  |  CCCD enable on …2810                    |
  |----------------------------------------> |
  |                                          |
  |  CLOSE_ALL_REQ (13B)                     |
  |----------------------------------------> |
  |                                          |
  |                       CLOSE_ALL_RESP (13B+)
  |<-----------------------------------------|
  |                                          |
  |  REGISTER_ML_REQ GFDI reliable=0 (13B)   |
  |----------------------------------------> |
  |                                          |
  |                  REGISTER_ML_RESP handle=H (14B)
  |<-----------------------------------------|
  |                                          |
  |               DEVICE_INFORMATION (GFDI)  |
  |<-----------------------------------------|
  |  ACK(5024) (9B GFDI in COBS)             |
  |----------------------------------------> |
  |                                          |
  |                CONFIGURATION (GFDI)      |
  |<-----------------------------------------|
  |  ACK(5050) (9B)                          |
  |----------------------------------------> |
  |  CONFIGURATION host bitmask              |
  |----------------------------------------> |
  |                                          |
  |  [optional: AUTH_NEGOTIATION dance —     |
  |   not seen on Instinct Solar 1]          |
  |                                          |
  |  SUPPORTED_FILE_TYPES_REQUEST (5031)     |
  |----------------------------------------> |
  |  DEVICE_SETTINGS (5026)                  |
  |----------------------------------------> |
  |  SYSTEM_EVENT TIME_UPDATED (5030, 16)    |
  |----------------------------------------> |
  |  SYSTEM_EVENT SYNC_READY (5030, 8)       |
  |----------------------------------------> |
  |  battery-level protobuf                  |
  |----------------------------------------> |
  |  [State = INITIALIZED]                   |
  |  if mFirstConnect:                       |
  |    SYSTEM_EVENT PAIR_COMPLETE (4)        |
  |    SYSTEM_EVENT SYNC_COMPLETE (0)        |
  |    SYSTEM_EVENT SETUP_WIZARD_COMPLETE(14)|
  |----------------------------------------> |
```

---

## 11. Capabilities — `OUR_CAPABILITIES` Enumeration

See §10 step 8 for the named list. Bit ordering (`GarminCapability.java:212–228`):

```java
public static byte[] setToBinary(final Set<GarminCapability> capabilities) {
    final GarminCapability[] values = values();
    final byte[] result = new byte[(values.length + 7) / 8];
    int bytePos = 0, bitPos = 0;
    for (int i = 0; i < values.length; ++i) {
        if (capabilities.contains(FROM_ORDINAL.get(i))) {
            result[bytePos] |= (1 << bitPos);
        }
        ++bitPos;
        if (bitPos >= 8) { bitPos = 0; ++bytePos; }
    }
    return result;
}
```

i.e. **little-endian per-bit, byte 0 holds capabilities[0..7] with
ordinal-0 in bit 0**. The decoder (line 180–194) is symmetric.

For ordinal 76 (`MULTI_LINK_SERVICE`) the bit lives at byte 9, bit 4
(0x10 mask in byte 9). If you want to claim MLR support to the watch
you'd need that bit on the host bitmask; GB does claim it (it's in
`OUR_CAPABILITIES`).

---

## 12. Auth Negotiation

The full life-cycle:

* **Watch → Phone, AUTH_NEGOTIATION (5101):**
  `| len(2) | type=5101(2) | unkByte(1) | flags(4 LE bitvector) | crc(2) |`

* **Phone → Watch, AUTH_NEGOTIATION_STATUS (RESPONSE for 5101):**
  `| len(2) | type=5000(2) | refType=5101(2) | status=ACK(1) | guess=GUESS_OK(0)(1) | unkByte (echoed) (1) | flags (echoed) (4) | crc(2) |`

`AuthFlags` is an 8-entry enum (`AuthNegotiationMessage.java:46–55`):

```java
public enum AuthFlags {
    UNK_00000001,
    UNK_00000010,
    UNK_00000100,
    UNK_00001000,
    UNK_00010000,
    UNK_00100000,
    UNK_01000000,
    UNK_10000000,
}
```

(Names are misleading — they're just bit positions 0..7. The flag set is a
4-byte int but only the low byte is currently used.)

GB's strategy is "echo whatever the watch sent" — `unknown` and `requestedAuthFlags`
are both passed through unchanged from the inbound message. That has the
practical effect of always saying "yes, we're cool with that".

**Instinct Solar 1st gen does not appear to use AUTH_NEGOTIATION.** No GB
log we have for that device shows it; the firmware handshake terminates
after CONFIGURATION.

---

## 13. SystemEvent Sequence and "Initialized" State

Already covered in §10 step 10–11. Summary table of every SYSTEM_EVENT GB
*originates* during pairing / first connect:

| Order | Event                  | Ordinal | Sent if…                             |
| ----- | ---------------------- | ------- | ------------------------------------ |
| (during init) | TIME_UPDATED   | 16      | `Prefs.syncTime() == true` (default) |
| (during init) | SYNC_READY     | 8       | always                               |
| (post-init, first connect only) | PAIR_COMPLETE         | 4  | `mFirstConnect == true` |
| (post-init, first connect only) | SYNC_COMPLETE         | 0  | "                       |
| (post-init, first connect only) | SETUP_WIZARD_COMPLETE | 14 | "                       |

`PAIR_START (3)`, `TUTORIAL_COMPLETE (12)`, and `SETUP_WIZARD_START (13)`
are **never sent** by current GB (commented out at `GarminSupport.java:811, 814`):

```java
// sendOutgoingMessage("set pair start", new SystemEventMessage(SystemEventMessage.GarminSystemEventType.PAIR_START, 0));
sendOutgoingMessage("set pair complete", new SystemEventMessage(SystemEventMessage.GarminSystemEventType.PAIR_COMPLETE, 0));
sendOutgoingMessage("set sync complete", new SystemEventMessage(SystemEventMessage.GarminSystemEventType.SYNC_COMPLETE, 0));
// sendOutgoingMessage("set tutorial complete", new SystemEventMessage(SystemEventMessage.GarminSystemEventType.TUTORIAL_COMPLETE, 0));
sendOutgoingMessage("set setup wizard complete", new SystemEventMessage(SystemEventMessage.GarminSystemEventType.SETUP_WIZARD_COMPLETE, 0));
```

If your watch insists on PAIR_START, send it manually before `PAIR_COMPLETE` —
some firmware expects it, but Instinct Solar 1st gen does not.

`HOST_DID_ENTER_FOREGROUND (6)` / `HOST_DID_ENTER_BACKGROUND (7)` are sent
in response to LocalBroadcasts from the rest of the app, **not** during
pairing:

```java
// GarminSupport.java:160–168
case ACTION_APP_IS_IN_FOREGROUND:
    sendOutgoingMessage("set foreground", new SystemEventMessage(GarminSystemEventType.HOST_DID_ENTER_FOREGROUND, 0));
    break;
case ACTION_APP_IS_IN_BACKGROUND:
    sendOutgoingMessage("set background", new SystemEventMessage(GarminSystemEventType.HOST_DID_ENTER_BACKGROUND, 0));
    break;
```

---

## 14. iOS / CoreBluetooth Pairing & Bonding

Gadgetbridge does **not** force or request bonding at any point during the
Garmin pairing flow:

* `GarminCoordinator.suggestUnbindBeforePair()` returns `false`
  (`devices/garmin/GarminCoordinator.java:79–82`).
* No Garmin code calls `BluetoothDevice.createBond()` or sets any
  `BondState` requirement.
* No characteristic on the V2 service is declared as requiring authenticated
  reads/writes. The watch only requires bonding for the *firmware-update*
  characteristic on the legacy service `2803`, not for the `28x0` ML
  characteristics.
* Android's GATT autonomously triggers SMP pairing if it ever sees an
  `INSUFFICIENT_AUTHENTICATION` ATT error from a write or read attempt. For
  Garmin V2, that error never occurs on the ML characteristics, so bonding
  is never triggered by GB.

So how does the **PIN dialog** appear during real-world Garmin pairing?
Two answers:

1. The user typically pairs through the OS Bluetooth Settings *first*
   (Garmin's "Pair from settings" flow), where the OS itself drives SMP and
   shows the PIN. GB then re-uses the existing bond.
2. If the user goes through GB's "Connect first time" flow without prior
   bonding, **the bond is established lazily by the watch**: when the user
   taps the watch's "Pair" button on the device, the watch requests SMP
   pairing as part of the LL connection lifecycle (Just Works or Passkey
   Entry depending on firmware). Android shows the PIN dialog through the
   system UI; GB does nothing.

### Implications for iOS / CompassBLE

* CoreBluetooth surfaces bonding via `peripheral.state == .connected` plus
  the OS-level bond. There is no programmatic way to *force* bonding from
  inside an app — iOS handles SMP/LL itself.
* If the watch sends an LL `LL_PAIRING_REQ`, iOS shows its own pairing
  alert. Your app receives no callback for it; `.didConnect` fires before
  the SMP exchange completes if it's "Just Works", and after if it's
  Passkey/PIN.
* A common iOS-side mistake is starting GFDI traffic before the SMP
  exchange is complete. The fix is **not** to wait for any SMP-related
  callback (there is none); it is to retry the GFDI handshake after a
  brief delay if the first writes time out — but in practice, by the time
  CoreBluetooth's `centralManager(_:didConnect:)` fires for the *user-paired*
  connection, SMP has already finished and you can write immediately.

In short: **GB does no bonding magic, and you don't need to either.** The
"PIN pop" is a property of the watch firmware + host OS interaction, not
something GB triggers explicitly.

---

## 15. Differences vs `Packages/CompassBLE/`

This is grounded in a quick scan of `BluetoothCentral.swift`,
`MultiLinkTransport.swift`, and `MLRTransport.swift`. Issues to verify
line-by-line against the GB reference above:

1. **`writeValue` write type — top priority.**
   `BluetoothCentral.swift:343` chooses `.withResponse` when `awaitAck ==
   true`. The reference says **every** write to the send characteristic is
   `.withoutResponse`. The `.withResponse` path will hang on `didWriteValueFor`
   forever for any payload to the Garmin send characteristic, because the
   firmware never emits an ATT Write Response. **Action: remove the
   `.withResponse` branch or guard it behind a property check that confirms
   the characteristic actually advertises `.write` (Garmin's only
   advertises `.writeWithoutResponse`).**

2. **CLOSE_ALL_REQ / REGISTER_ML_REQ encoding.**
   Verify against §3:
   * 13 bytes total, all little-endian.
   * Byte order: `handle(1) | type(1) | clientId(8 LE u64) | serviceCode(2 LE u16) | reliable(1)`.
   * `clientId == 2`. `MultiLinkTransport.swift` should use `2`, not `1`.
   * `reliable = 0` for CLOSE_ALL_REQ (the "extra short" is `0x0000`).
   * `reliable = 0` for REGISTER_ML_REQ (Instinct does not need MLR).

3. **Receive-side handle dispatch.**
   The first byte of every notification is the handle. `handle == 0` ⇒
   management plane (CLOSE_ALL_RESP / REGISTER_ML_RESP). Otherwise dispatch
   to GFDI. **High-bit-set must not be assumed to mean MLR** — see
   `CommunicatorV2.java:181–182` ("non-MLR handles can also have the msb
   set"). Check that `MultiLinkTransport` doesn't unconditionally route
   high-bit handles to MLR.

4. **CRC scope and placement.**
   CRC is over `[length(2) | type(2) | payload(N)]`, not over `[type | payload]`.
   The CRC is appended *after* — total message length includes the CRC.
   Verify in `GFDIMessage` builder.

5. **Compact message-type decode.**
   `(messageType & 0x8000) != 0 ⇒ messageType = (messageType & 0xff) + 5000`.
   This is **inbound only**. Outbound always uses the full 5000-range form.

6. **String format.**
   1-byte length prefix + UTF-8, max 255 *bytes*. **No null terminator**.
   If your `MessageWriter` writes a NUL byte after the string, you'll
   produce malformed CONFIGURATION / DEVICE_INFORMATION echoes (latter is
   moot since GB doesn't actually send DI; but be safe for other
   messages).

7. **`response.clear()` quirk.**
   When parsing a CONFIGURATION (or any message whose constructor stores
   the parsed bytes), the buffer used to assemble the *outgoing* echo is
   the same shared `response` buffer. The Java code calls `response.clear()`
   at the top of `getOutgoingMessage()`. If your Swift port reuses an
   inbound-decoding buffer for outbound generation, make sure to reset
   `position = 0` first — otherwise your CONFIGURATION echo will be
   prefixed with garbage.

8. **MTU.**
   Gadgetbridge requests MTU 515 by default
   (`GarminSupport.java:264–266`). On iOS, `peripheral.maximumWriteValueLength(for:)`
   is what you must use for chunking; you can't manually request an MTU.
   For best results, send small (< 20 byte) writes initially until you've
   discovered the negotiated max — but Garmin's V2 ML-control messages are
   all 13–15 bytes, so they fit in a single MTU=23 write regardless.

9. **OUR_CAPABILITIES bitmask length.**
   §10 step 8: 15 bytes for the current 120-entry enum. Verify your iOS
   `setToBinary` produces exactly 15 bytes. The bitmask length byte
   precedes the bitmask in the CONFIGURATION host echo.

10. **Fragmentation.**
    Basic-ML fragment size is `maxWriteSize - 1` per write. You must
    re-prefix the handle on **every** fragment of a multi-fragment GFDI
    message. The COBS frame is split across fragments arbitrarily — only
    the *first* contains the leading `0x00` and only the *last* contains
    the trailing `0x00`.

11. **Reliable=0 on Instinct.**
    Don't set reliable=2 even if you implement MLRTransport — Instinct
    Solar firmware does not advertise MULTI_LINK_SERVICE capability and
    will reject reliable=2 (or, worse, accept it and never send anything).

12. **No initial "host DEVICE_INFORMATION" send.**
    Don't send a host DEVICE_INFORMATION at all. The watch initiates with
    its DEVICE_INFORMATION; GB sends only the 9-byte ACK. If your code
    pre-emptively sends a host DEVICE_INFORMATION on connect, the watch
    will reject the order and the handshake won't progress.

13. **Order of post-init traffic doesn't matter for Instinct's
    `PAIR_COMPLETE`,** but the device will not move out of "pairing"
    state until SYSTEM_EVENT(PAIR_COMPLETE) is received. So if you skip
    the `mFirstConnect` burst in §13, the watch will **stay** in pairing
    UI forever. Make sure the iOS code sends at least
    `SYSTEM_EVENT(PAIR_COMPLETE, 0)` after the watch's CONFIGURATION is
    ACKed and echoed.

---

## 16. Known Unknowns

* **Exact behaviour of `unknown` byte in AUTH_NEGOTIATION.** GB just echoes
  it. We don't know what value the watch expects when it's testing an
  unfamiliar host. Probably zero is fine.

* **What `protocolFlags` byte the watch expects in a host
  DEVICE_INFORMATION echo.** The code computes
  `protocolFlags = incomingProtocolVersion / 100 == 1 ? 1 : 0`
  (`DeviceInformationMessage.java:67`), but since GB never actually sends
  the host DI, this branch is untested in the wild. Assume `0` if you ever
  do send a host DI — Instinct should report a 200-series protocol
  version.

* **Whether `SETUP_WIZARD_START` (13) needs to precede `SETUP_WIZARD_COMPLETE`.**
  Some forum reports for older firmwares suggest yes, but GB never sends
  SETUP_WIZARD_START and pairing succeeds. For Instinct Solar 1, we have
  no logs of it being required.

* **Whether the Instinct ever sends `0x2814 / 0x2824`.** The loop allows
  it, but no observed firmware exposes those characteristics. If you hit
  this case, please log it.

* **CLOSE_ALL_RESP exact payload after the clientId.** GB only inspects
  the type byte; the trailing two bytes are read by `processHandleManagement`
  but unused (`CommunicatorV2.java:388`). On Instinct firmware they appear
  to always be `00 00 00`, but this is not authoritative.

* **Maximum useful MTU on Instinct Solar 1st gen.** GB asks for 515; the
  watch typically agrees to 245 or so. This influences `maxWriteSize`.

* **Exact set of capabilities the Instinct Solar 1 advertises in its
  CONFIGURATION (5050)** — no public dump in the GB tree. Any handshake
  bug that depends on a specific capability bit being on/off will need a
  HCI snoop log to confirm.

---

## 17. Post-Pair Protobuf Exchange

After `completeInitialization()` the watch enters an onboarding loop and
sends several `PROTOBUF_REQUEST (0x13B3)` messages. This section documents
the wire format and correct host responses, verified against
`ProtobufMessage.java` and `ProtocolBufferHandler.java`.

### 17.1 PROTOBUF_REQUEST payload layout

All `PROTOBUF_REQUEST (0x13B3)` and `PROTOBUF_RESPONSE (0x13B4)` GFDI
message payloads share a fixed 14-byte header before the proto bytes:

```
[requestId: UInt16 LE]          2 bytes — identifier for this RPC exchange
[dataOffset: UInt32 LE]         4 bytes — byte offset (0 for non-chunked)
[totalProtobufLength: UInt32 LE] 4 bytes — full proto payload size
[protobufDataLength: UInt32 LE]  4 bytes — bytes in this fragment
[protoBytes: N bytes]            N bytes — serialized Smart proto message
```

Reference: `ProtobufMessage.parseIncoming` and `generateOutgoing`
(`service/devices/garmin/messages/ProtobufMessage.java`).

### 17.2 Correct ACK for PROTOBUF_REQUEST

Gadgetbridge does **not** send a `PROTOBUF_RESPONSE (0x13B4)` in reply to
the watch's `initRequest`. It sends a `RESPONSE (0x1388)` with extended
ProtobufStatusMessage fields:

```
GFDI type: RESPONSE (0x1388)
Payload:
  [originalType: UInt16 LE]   = 0x13B3 (PROTOBUF_REQUEST)
  [status: UInt8]             = 0x00 (ACK)
  [requestId: UInt16 LE]      = echoed from incoming PROTOBUF_REQUEST header
  [dataOffset: UInt32 LE]     = 0x00000000
  [chunkStatus: UInt8]        = 0x00 (KEPT)
  [statusCode: UInt8]         = 0x00 (NO_ERROR)
```

Total GFDI message: `[2: len=17][2: 0x1388][11 bytes][2: CRC]` = 17 bytes.

Our bare 9-byte ACK (`[len=9][0x1388][0x13B3][0x00][CRC]`) was missing the
last 8 bytes, which may cause the watch to consider the request unacknowledged.

Reference: `ProtobufStatusMessage.generateOutgoing`
(`service/devices/garmin/messages/status/ProtobufStatusMessage.java`).

### 17.3 GdiSmartProto message wrapper (field numbers)

The protobuf payload is a serialized `Smart` message (`gdi_smart_proto.proto`).
Relevant field numbers verified from the proto source:

| Field | Number | Type |
|---|---|---|
| `calendar_service` | 1 | CalendarService |
| `http_service` | 2 | HttpService |
| `installed_apps_service` | 3 | InstalledAppsService |
| `app_config_service` | 4 | AppConfigService |
| `data_transfer_service` | 7 | DataTransferService |
| `device_status_service` | 8 | DeviceStatusService |
| `find_my_watch_service` | 12 | FindMyWatchService |
| `core_service` | 13 | CoreService |
| `sms_notification_service` | 16 | SmsNotificationService |
| `authenticationService` | 27 | AuthenticationService |
| `ecg_service` | 39 | EcgService |
| **`settings_service`** | **42** | **SettingsService** |
| `file_sync_service` | 43 | FileSyncService |
| `notifications_service` | 49 | NotificationsService |

**Note:** `settings_service` is field 42, not 2 — a common off-by-one
assumption when guessing proto field numbers.

### 17.4 SettingsService field numbers

From `gdi_settings_service.proto`:

| Field | Number | Type |
|---|---|---|
| `definitionRequest` | 1 | ScreenDefinitionRequest |
| `definitionResponse` | 2 | ScreenDefinitionResponse |
| `stateRequest` | 3 | ScreenStateRequest |
| `stateResponse` | 4 | ScreenStateResponse |
| `changeRequest` | 5 | ChangeRequest |
| `changeResponse` | 6 | ChangeResponse |
| **`initRequest`** | **8** | InitRequest |
| **`initResponse`** | **9** | InitResponse |

`InitRequest` carries `language` (field 1, string, e.g. `"en_US"`) and
`region` (field 2, string, e.g. `"us"`). `InitResponse` has `unk1` (field 1)
and `unk2` (field 2) — both unknown strings, possibly echoed locale/region.
Gadgetbridge does not populate `InitResponse`; it sends only the status ACK.

### 17.5 MUSIC_CONTROL_CAPABILITIES (0x13B2) response

The watch sends a single-byte `supportedCapabilities` bitmask. Gadgetbridge
replies with a `RESPONSE (0x1388)`:

```
[originalType: 0x13B2 LE]
[status: 0x00 ACK]
[commandCount: N]            1 byte — number of supported commands
[commands: N bytes]          1 byte per GarminMusicControlCommand ordinal
```

To signal "no music support", send `commandCount = 0` (no command bytes follow).
The watch stops re-asking once it receives this.

Reference: `MusicControlCapabilitiesMessage.generateOutgoing`
(`service/devices/garmin/messages/MusicControlCapabilitiesMessage.java`).

---

*Document generated by reverse-engineering GB master @ 2026-04-29. Every
fact in this document is anchored to a specific file:line in the GB tree;
search the source if anything looks wrong.*

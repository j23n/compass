# Gadgetbridge Instinct (and Garmin generic) Sync — Byte-Level Reference

This document picks up where
[`gadgetbridge-instinct-pairing.md`](./gadgetbridge-instinct-pairing.md) ends
— at the moment **Gadgetbridge** transitions the device to
`GBDevice.State.INITIALIZED` — and walks through everything that happens
afterwards on an established Multi-Link / GFDI / V2 link: time sync, file
listing, file download (watch → phone), file upload (phone → watch),
and the supporting/gating messages.

It is written for engineers re-implementing this on iOS in the
`compass` project, so message layouts are spelled out byte-by-byte and
cross-referenced to the Gadgetbridge source.

All citations refer to the Gadgetbridge `master` branch as fetched on
2026-04-29 from <https://codeberg.org/Freeyourgadget/Gadgetbridge>. Paths
shown without a prefix live under
`app/src/main/java/nodomain/freeyourgadget/gadgetbridge/`.

The pairing doc already covered the lower layers (Multi-Link, COBS, GFDI
length+CRC framing, the `& 0x8000` compact-type encoding, `MessageWriter` /
`MessageReader` conventions, capability negotiation, auth, and the four
`SystemEvent`s that bring the link to `INITIALIZED`). This doc assumes
those, and refers back where useful. **Every payload below is the GFDI
payload that goes inside a length+type+payload+CRC GFDI frame, then COBS,
then Multi-Link.**

---

## Table of Contents

1. [Sync Orchestration / State Machine](#1-sync-orchestration--state-machine)
2. [Time Sync](#2-time-sync)
3. [Supported File Types Negotiation](#3-supported-file-types-negotiation)
4. [Watch-Initiated SYNCHRONIZATION + FILTER (the legacy sync trigger)](#4-watch-initiated-synchronization--filter-the-legacy-sync-trigger)
5. [File Listing — The Root Directory Download](#5-file-listing--the-root-directory-download)
6. [File Download (Watch → Phone)](#6-file-download-watch--phone)
7. [Per-Chunk CRC and the Running CRC State](#7-per-chunk-crc-and-the-running-crc-state)
8. [File Upload (Phone → Watch)](#8-file-upload-phone--watch)
9. [`SET_FILE_FLAG` — Marking Files Archived/Deleted](#9-set_file_flag--marking-files-archived-deleted)
10. [Other Messages That Gate or Accompany Sync](#10-other-messages-that-gate-or-accompany-sync)
11. [The "New Sync Protocol" (`FileSyncService`)](#11-the-new-sync-protocol-filesyncservice)
12. [GFDI Message Type Catalog](#12-gfdi-message-type-catalog)
13. [Concrete Hex-Dump Examples](#13-concrete-hex-dump-examples)
14. [iOS Implementation Guidance and Known Unknowns](#14-ios-implementation-guidance-and-known-unknowns)

---

## 1. Sync Orchestration / State Machine

### 1.1 Where "INITIALIZED" actually happens

The pairing doc described the four `SystemEvent`s that the watch sends
post-auth (`SYNC_READY`, `HOST_DID_ENTER_FOREGROUND`, …). The transition
to `GBDevice.State.INITIALIZED` is performed by `completeInitialization()`,
which is triggered by a `CapabilitiesDeviceEvent` — that event is, in
turn, emitted by an incoming `ConfigurationMessage` (5050) carrying the
watch's `OUR_CAPABILITIES` byte-bitmask.

```java
// service/devices/garmin/GarminSupport.java:395–413  (evaluateGBDeviceEvent)
} else if (deviceEvent instanceof CapabilitiesDeviceEvent) {
    final Set<GarminCapability> capabilities = ((CapabilitiesDeviceEvent) deviceEvent).capabilities;
    completeInitialization();
    if (capabilities.contains(GarminCapability.REALTIME_SETTINGS)) {
        // … kick off a Realtime Settings init via protobuf …
    }
}
```

`completeInitialization()` is the gate. Anything you implement on iOS
should fire this same sequence the first time you see a `ConfigurationMessage`
on the link:

```java
// GarminSupport.java:789–818
private void completeInitialization() {
    if (gbDevice.getState() == GBDevice.State.INITIALIZED) { /* prevent double-init */ return; }
    sendOutgoingMessage("request supported file types", new SupportedFileTypesMessage());        // §3
    sendDeviceSettings();                                                                        // §10.3
    if (GBApplication.getPrefs().syncTime()) {
        onSetTime();   // -> SystemEvent TIME_UPDATED, watch will then poll back via 5052       // §2
    }
    sendOutgoingMessage("set sync ready",
        new SystemEventMessage(SystemEventMessage.GarminSystemEventType.SYNC_READY, 0));
    enableBatteryLevelUpdate();   // protobuf
    gbDevice.setUpdateState(GBDevice.State.INITIALIZED, getContext());

    if (mFirstConnect) {
        sendOutgoingMessage("set pair complete",
            new SystemEventMessage(SystemEventMessage.GarminSystemEventType.PAIR_COMPLETE, 0));
        sendOutgoingMessage("set sync complete",
            new SystemEventMessage(SystemEventMessage.GarminSystemEventType.SYNC_COMPLETE, 0));
        sendOutgoingMessage("set setup wizard complete",
            new SystemEventMessage(SystemEventMessage.GarminSystemEventType.SETUP_WIZARD_COMPLETE, 0));
        this.mFirstConnect = false;
    }
}
```

So the post-pairing sequence the phone always sends is:

| # | Message                              | GFDI ID |
|---|--------------------------------------|---------|
| 1 | `SUPPORTED_FILE_TYPES_REQUEST`       | 5031    |
| 2 | `DEVICE_SETTINGS` (3 settings)       | 5026    |
| 3 | `SystemEvent(TIME_UPDATED)`          | 5030    |
| 4 | `SystemEvent(SYNC_READY)`            | 5030    |
| 5 | A protobuf battery-status request    | 5043    |

Plus, if it's the first connect, a closing `PAIR_COMPLETE`, `SYNC_COMPLETE`,
and `SETUP_WIZARD_COMPLETE` triplet of `SystemEvent`s.

After this point the pump is **bidirectional and asynchronous**: the
watch decides when it wants to push files (it'll send a
`SynchronizationMessage` (5037) — see §4), and the phone can also ask
to fetch via `onFetchRecordedData()`.

### 1.2 The receive pump

There is no explicit "state machine" object. Inbound messages come
through `onMessage(byte[])`:

```java
// GarminSupport.java:326–367
@Override
public void onMessage(final byte[] message) {
    if (message == null) return;
    GFDIMessage parsedMessage = GFDIMessage.parseIncoming(message);
    if (parsedMessage == null) return;

    GFDIMessage followup = null;
    for (MessageHandler han : messageHandlers) {
        followup = han.handle(parsedMessage);
        if (followup != null) break;
    }
    sendAck("send status", parsedMessage);          // 1. ACK frame for the inbound message
    sendOutgoingMessage("send reply", parsedMessage); // 2. reply (e.g. CurrentTimeRequest builds its own response inside generateOutgoing())
    sendOutgoingMessage("send followup", followup);   // 3. handler-generated follow-up
    for (final GBDeviceEvent event : parsedMessage.getGBDeviceEvent()) {
        evaluateGBDeviceEvent(event);
    }
    processDownloadQueue();                           // 4. drain pending downloads
}
```

Three-step output ordering matters and is reproduced exactly in this
order: **status/ack frame → message-as-reply → handler follow-up**.
Then `processDownloadQueue()` is poked, which advances the file
download FSM (§6).

### 1.3 The handler chain

```java
// GarminSupport.java:177–183
fileTransferHandler   = new FileTransferHandler(this);
notificationsHandler  = new NotificationsHandler();
messageHandlers.add(fileTransferHandler);
messageHandlers.add(protocolBufferHandler);
messageHandlers.add(notificationsHandler);
```

`FileTransferHandler` is consulted first; that's the bit you must port to
iOS in full. `ProtocolBufferHandler` covers the protobuf-based modern
services (battery, settings, FindMyWatch, FileSync — §11). The
notifications handler can be skipped for a basic port.

The `handle(GFDIMessage)` contract: if a handler returns a non-null
`GFDIMessage`, that becomes the **followup** (sent after the inbound
message's own ACK and its built-in reply). If it returns null the
chain continues to the next handler.

The dispatch inside `FileTransferHandler.handle()`:

```java
// FileTransferHandler.java:93–110
public GFDIMessage handle(GFDIMessage message) {
    if (message instanceof DownloadRequestStatusMessage)    download.processDownloadRequestStatusMessage(...);
    else if (message instanceof FileTransferDataMessage)    download.processDownloadChunkedMessage(...);
    else if (message instanceof CreateFileStatusMessage)    return upload.setCreateFileStatusMessage(...);
    else if (message instanceof UploadRequestStatusMessage) return upload.setUploadRequestStatusMessage(...);
    else if (message instanceof FileTransferDataStatusMessage) return upload.processUploadProgress(...);
    else if (message instanceof SynchronizationMessage)     return processSynchronizationMessage(...);  // -> FilterMessage
    else if (message instanceof FilterStatusMessage)        return initiateDownload();                  // -> root DIRECTORY DownloadRequest
    return null;
}
```

That short list **is** the legacy sync state machine.

### 1.4 Trigger paths into the file-download queue

There are three entry points that can push items onto `filesToDownload`:

1. **Watch-initiated** (default after pairing): the watch sends
   `SynchronizationMessage` (5037). The handler returns `FilterMessage`
   (5007). The watch ACKs with `FilterStatusMessage`, the handler then
   returns `initiateDownload()` which queues the **root directory entry
   (`fileIndex = 0`, `FILETYPE.DIRECTORY`)**. Once the directory file
   downloads, its rows are parsed in `parseDirectoryEntries` and each
   matching `DirectoryEntry` is appended to `filesToDownload`.
2. **Phone-initiated** via `onFetchRecordedData()`
   (`GarminSupport.java:511`). The user taps "Fetch activity data" in
   the GB UI. This calls `fileTransferHandler.initiateDownload()`
   directly — same root directory request as above.
3. **Phone-initiated debug logs** via
   `onFetchRecordedData(TYPE_DEBUGLOGS)` — pushes a hard-coded
   `DEVICE_XML` directory entry (`fileIndex = 0xFFFD`, type 8/255) onto
   the queue (`GarminSupport.java:512–515`).

`processDownloadQueue()` picks the next item, peeks at whether the
file is already on disk, and if not sends a `DownloadRequestMessage`
(5002) — that's what kicks off the download FSM (§6).

`onTestNewFunction()` is empty in current master
(`GarminSupport.java:1493–1495`); not a useful trigger.

### 1.5 The FSM at a glance

```
INITIALIZED
   │
   │ watch sends ConfigurationMessage(5050)  ─► CapabilitiesDeviceEvent
   ▼
completeInitialization()  ── (sends 5031, 5026, 5030 TIME_UPDATED, 5030 SYNC_READY)
   │
   │   (Watch eventually sends SynchronizationMessage(5037) when it has fresh data)
   ▼
SynchronizationMessage(5037, type=0/1/2, bitmask)
   │
   │  shouldProceed()? (checks WORKOUTS|ACTIVITIES|ACTIVITY_SUMMARY|SLEEP bits)
   ▼
PHONE → FilterMessage(5007, type=UNK_3)
WATCH → FilterStatusMessage(5007 + & 0x8000 status, ACK)
PHONE → DownloadRequestMessage(5002, fileIndex=0, …)         ◄── root directory
WATCH → DownloadRequestStatusMessage(canProceed, maxFileSize)
WATCH → FileTransferDataMessage(5004) × N                    ◄── directory body
PHONE  ── parses 16-byte DirectoryEntry rows ──►  filesToDownload[]
PHONE → DownloadRequestMessage(5002, fileIndex=N, …)         ◄── one per file
…
PHONE → SystemEvent(SYNC_COMPLETE) when filesToDownload is drained AND no pending FIT to import
```

---

## 2. Time Sync

### 2.1 The two paths

There is **no "set time"** message that the phone sends unilaterally.
Instead:

| Direction      | What                                               | Code path                     |
|----------------|----------------------------------------------------|-------------------------------|
| Phone → Watch  | `SystemEvent(TIME_UPDATED)`, value=0 (just a poke) | `GarminSupport.java:990`      |
| Watch → Phone  | `CurrentTimeRequestMessage` (5052) with `referenceID` | watched-side initiated     |
| Phone → Watch  | `RESPONSE(5000)` carrying current time, TZ, DST, next-DST-end, next-DST-start | `CurrentTimeRequestMessage.java:81–91` |

So the protocol is **request-driven from the watch**: the phone tells the
watch "time changed, ask me again", the watch immediately fires a
`CURRENT_TIME_REQUEST`, and the phone fills in the response.

### 2.2 The Garmin epoch

Wall-clock seconds use a Garmin-specific epoch:

```java
// service/devices/garmin/GarminTimeUtils.java:8–12
public static final int GARMIN_TIME_EPOCH = 631065600;   // 1989-12-31T00:00:00Z

public static int unixTimeToGarminTimestamp(int unixTime) {
    return unixTime - GARMIN_TIME_EPOCH;
}
```

This applies *everywhere* a Garmin "timestamp" appears in the wire
format — including FIT directory entries (§5).

### 2.3 `CURRENT_TIME_REQUEST` (id 5052) — incoming wire format

```
offset  size  field
0       2     packet_size (incl. CRC)               little-endian, set by GFDIMessage.addLengthAndChecksum
2       2     message_type = 5052 (0x14 0x14)
4       4     reference_id (uint32 LE)
…       2     CRC-16 (Garmin variant)
```

`MessageReader` reads only the `reference_id`
(`CurrentTimeRequestMessage.java:21–25`).

### 2.4 The phone's reply (a `RESPONSE`/5000 frame)

The reply is **emitted from inside `generateOutgoing()` of the
incoming-message object itself** (rather than a separate handler) — that's
the second sender slot of the receive pump (§1.2 step 2). So the phone
literally sends a `RESPONSE` (5000) frame, whose payload is:

```java
// CurrentTimeRequestMessage.java:81–91
writer.writeShort(0);                              // packet size placeholder
writer.writeShort(GarminMessage.RESPONSE.getId()); // 5000
writer.writeShort(this.garminMessage.getId());     // 5052 — the message being responded to
writer.writeByte(Status.ACK.ordinal());            // 0
writer.writeInt(referenceID);                      // echo
writer.writeInt(garminTimestamp);                  // unix - GARMIN_TIME_EPOCH
writer.writeInt(timeZoneOffset);                   // seconds, signed
writer.writeInt(nextTransitionEndsGarminTs);       // 0 if none
writer.writeInt(nextTransitionStartsGarminTs);     // 0 if none
```

The `dstOffset` is computed (`zoneRules.getDaylightSavings(now).getSeconds()`)
but **not written** in the response — it's only logged.

Field semantics:

- `timeZoneOffset` is `TimeZone.getDefault().getOffset(now)/1000`, i.e.
  total UTC offset including any current DST. Signed 32-bit.
- `nextTransitionStartsGarminTs` / `nextTransitionEndsGarminTs` are the
  Garmin-epoch timestamps of the next two `ZoneOffsetTransition`s in
  `zoneRules` (so for a year with one summer-time transition each way,
  they bracket the upcoming change). Both 0 if the local zone has no
  upcoming transition.

`addLengthAndChecksum()` then prepends the payload length and appends
the CRC; total response is 21 + 2 + 2 = **25 bytes** of GFDI payload.

### 2.5 When the phone pokes

```java
// GarminSupport.java:988–991
@Override
public void onSetTime() {
    sendOutgoingMessage("set time",
        new SystemEventMessage(SystemEventMessage.GarminSystemEventType.TIME_UPDATED, 0));
}
```

`onSetTime()` is invoked by Gadgetbridge on:

- `completeInitialization()` (if `GBApplication.getPrefs().syncTime()` is
  true — `GarminSupport.java:798–800`).
- The Android `ACTION_TIMEZONE_CHANGED` / `ACTION_TIME_CHANGED` system
  broadcasts (handled by the GB framework, not the Garmin code).

The actual current time/TZ never travels in `onSetTime()`'s payload — it
only fits in 2-byte `SystemEvent` (event=`TIME_UPDATED` ordinal **16**,
value=`0`). The watch then immediately sends a `CURRENT_TIME_REQUEST` and
the phone fills in the values.

### 2.6 `SetDeviceSettingsMessage` (5026) carries time fields too

Note that `GarminDeviceSetting` (in `SetDeviceSettingsMessage.java:42–52`)
has slots `CURRENT_TIME`, `DAYLIGHT_SAVINGS_TIME_OFFSET`,
`TIME_ZONE_OFFSET`, `NEXT_DAYLIGHT_SAVINGS_START`,
`NEXT_DAYLIGHT_SAVINGS_END`. Gadgetbridge's `sendDeviceSettings()` uses
**only** the auto-upload / weather-conditions / weather-alerts settings
(`GarminSupport.java:980–986`); it never pushes time via 5026. The
time sync path is purely the request/response on 5052/5000.

---

## 3. Supported File Types Negotiation

`SupportedFileTypesMessage` (id 5031) is sent by the phone in
`completeInitialization()` and is **a content-less request frame**:

```java
// messages/SupportedFileTypesMessage.java:9–15
writer.writeShort(0);                              // length placeholder
writer.writeShort(this.garminMessage.getId());     // 5031
return true;
```

The watch responds with a status frame (`5031 | 0x8000` compact-type
encoded; `SupportedFileTypesStatusMessage`). The body is:

```
1 byte   Status.ACK (0)
1 byte   typeCount
typeCount × {
    1 byte    fileDataType   (e.g. 128 for FIT)
    1 byte    fileSubType    (e.g. 4 = ACTIVITY)
    1 byte    nameLen
    nameLen bytes UTF-8 garminDeviceFileType  (e.g. "garmin/activity")
}
```

Per `SupportedFileTypesStatusMessage.java:22–43`. The list ends up in
`GarminSupport.supportedFileTypeList` via a
`SupportedFileTypesDeviceEvent` (lines 444–446). Gadgetbridge does not
gate sync on the list contents; it's used to (a) understand what FIT
sub-types the watch will push and (b) skip unknown types unless the
"fetch unknown files" pref is enabled (see §5).

---

## 4. Watch-Initiated SYNCHRONIZATION + FILTER (the legacy sync trigger)

The watch decides "I have data" by emitting `SynchronizationMessage`
(id 5037). Wire format:

```
1 byte    type      (0/1/2; SynchronizationMessage.SynchronizationType)
1 byte    bitmaskSize  (4 or 8)
4 or 8 bytes  bitmask  (LE), one bit per FileType ordinal
```

`SynchronizationMessage.java:22–37`. The bit positions (relevant ones):

| Bit | Name              |
|-----|-------------------|
| 3   | WORKOUTS          |
| 5   | ACTIVITIES        |
| 8   | SOFTWARE_UPDATE   |
| 21  | ACTIVITY_SUMMARY  |
| 26  | SLEEP             |

`shouldProceed()` is true if any of `WORKOUTS|ACTIVITIES|ACTIVITY_SUMMARY|SLEEP`
are set (`SynchronizationMessage.java:39–42`). If so, the
`FileTransferHandler.processSynchronizationMessage` returns a
`FilterMessage` (id 5007) — sent as the followup. The `FilterMessage`
payload is hard-coded:

```java
// messages/FilterMessage.java:11–18
writer.writeShort(0);                          // length placeholder
writer.writeShort(this.garminMessage.getId()); // 5007
writer.writeByte(FilterType.UNK_3.ordinal());  // 3
```

i.e. **`writeByte(3)` and that's it**. The semantics of the `FilterType`
byte are unknown but Gadgetbridge always uses 3.

The watch ACKs with a `FilterStatusMessage` (5007 | 0x8000 compact-type),
which the handler converts into the **root directory download request**
(`FileTransferHandler.java:107–108` → `initiateDownload()`).

---

## 5. File Listing — The Root Directory Download

The "directory" on a Garmin watch is itself a file: `fileIndex = 0`,
type/subtype 0/0 (`FileType.FILETYPE.DIRECTORY`). To enumerate files
you literally download index 0 and parse the body.

### 5.1 Request

```java
// FileTransferHandler.java:124–127
public DownloadRequestMessage initiateDownload() {
    download.setCurrentlyDownloading(new FileFragment(
        new DirectoryEntry(0, FileType.FILETYPE.DIRECTORY, 0, 0, 0, 0, null)));
    return new DownloadRequestMessage(0, 0, DownloadRequestMessage.REQUEST_TYPE.NEW, 0, 0);
}
```

`DownloadRequestMessage` (5002) wire format
(`messages/DownloadRequestMessage.java:27–37`):

```
2 bytes  packet size
2 bytes  msg type (5002)
2 bytes  fileIndex   (0 for root directory; 0xFFFD for DEVICE_XML; 0..N for individual files)
4 bytes  dataOffset  (0 for a NEW request; resume offset for CONTINUE)
1 byte   requestType (REQUEST_TYPE.CONTINUE=0, NEW=1)
2 bytes  crcSeed     (0 for NEW; running CRC of bytes already received for CONTINUE)
4 bytes  dataSize    (max bytes to send; 0 = "everything"; for CONTINUE the remainder)
```

For a brand-new directory request, all numeric fields are 0 except
`requestType=1` (NEW). Total GFDI payload: 17 bytes + 2-byte CRC.

### 5.2 Watch's `DownloadRequestStatus` reply

`5002 | 0x8000` compact-type. Body
(`messages/status/DownloadRequestStatusMessage.java:15–29`):

```
1 byte   status        (0 = ACK)
1 byte   downloadStatus (DownloadStatus enum: 0=OK, 1=INDEX_UNKNOWN, 2=INDEX_NOT_READABLE,
                                              3=NO_SPACE_LEFT, 4=INVALID, 5=NOT_READY, 6=CRC_INCORRECT)
4 bytes  maxFileSize    (uint32 LE — the total bytes the watch is about to push)
```

If `status==ACK && downloadStatus==OK` (`canProceed()`), the
`FileFragment` allocates a `ByteBuffer` of `maxFileSize` and waits for
chunks. Otherwise the download is marked failed.

### 5.3 `FILE_TRANSFER_DATA` chunks (id 5004)

The watch then emits one or more `FILE_TRANSFER_DATA` frames. Wire
format (`messages/FileTransferDataMessage.java:31–39, 53–63`):

```
2 bytes  packet size
2 bytes  msg type (5004)
1 byte   flags                (always 0 in GB)
2 bytes  crc                  (running CRC after appending this chunk's data; see §7)
4 bytes  dataOffset           (LE, absolute offset of this chunk in the file)
N bytes  payload bytes
```

Phone behaviour (`FileTransferHandler.Download.processDownloadChunkedMessage`,
`FileTransferHandler.java:155–164`):

1. Verify `dataOffset == dataHolder.position()` (else "Received message
   that was already received").
2. Recompute the running CRC by feeding the new bytes into
   `ChecksumCalculator.computeCrc(runningCrc, message, 0, length)`
   (`FileTransferHandler.java:393–395`).
3. Verify watch's `crc` matches; throw if not.
4. Append the bytes to the buffer.
5. If buffer is full → `processCompleteDownload()`; otherwise call
   `deviceSupport.onFileDownloadProgress(position)`.

The phone sends a per-chunk ack — that's the
`FileTransferDataStatusMessage` produced by `getStatusMessage()` and
emitted by the receive pump's `sendAck("send status", parsedMessage)`
call. Wire format
(`messages/status/FileTransferDataStatusMessage.java:48–58`):

```
2 bytes  packet size
2 bytes  msg type = 5000 (RESPONSE)
2 bytes  responding-to = 5004
1 byte   status (0=ACK)
1 byte   transferStatus (0=OK, 1=RESEND, 2=ABORT, 3=CRC_MISMATCH, 4=OFFSET_MISMATCH, 5=SYNC_PAUSED)
4 bytes  dataOffset (the offset *after* the just-received chunk; serves as the next-byte cursor)
```

i.e. the per-chunk ACK explicitly tells the watch the next byte offset
the phone expects — that is how flow control / resume works.

### 5.4 Parsing the directory body

When the buffer fills, `processCompleteDownload()` either runs the new
sync protocol shortcut (§11) or parses 16-byte rows
(`FileTransferHandler.java:214–256`):

```
struct DirectoryEntry (16 bytes, little-endian):
    uint16 fileIndex          // 0..N; the value to put in DownloadRequestMessage
    uint8  fileDataType       // 128 for FIT files, 255 for "other", 8 for DEVICE_XML
    uint8  fileSubType        // see FileType.FILETYPE table below
    uint16 fileNumber         // type-specific; opaque
    uint8  specificFlags      // type-specific; opaque
    uint8  fileFlags          // see SetFileFlagsMessage.FileFlags
    uint32 fileSize           // total bytes
    uint32 fileTimestamp      // GARMIN_TIME_EPOCH-relative seconds
```

If `fileSize % 16 != 0` the parser throws "Invalid directory data length".
A zero row (all fields zero) is explicitly skipped to avoid an infinite
loop ("Ignoring … to avoid infinite loop").

The default filter `FILE_TYPES_TO_PROCESS` (FileTransferHandler.java:64–73)
is:

```
DIRECTORY, ACTIVITY, MONITOR, METRICS, CHANGELOG, HRV_STATUS, SLEEP, SKIN_TEMP
```

Any other type is ignored unless the user pref `fetchUnknownFiles` is
enabled.

### 5.5 FIT file sub-types

From `FileType.java:37–98` (this is the canonical list — not all watches
expose all of them, but all are part of the wire vocabulary):

| Type/Subtype | Symbol           | Notes                                |
|--------------|------------------|--------------------------------------|
| 0/0          | DIRECTORY        | Root directory file (fileIndex=0)    |
| 1/0          | UNKNOWN_1_0      | Venu 3                               |
| 8/255        | DEVICE_XML       | hardcoded fileIndex=0xFFFD           |
| 128/1        | DEVICE_1         |                                      |
| 128/2        | SETTINGS         | uploadable via CreateFile            |
| 128/3        | SPORTS           |                                      |
| 128/4        | ACTIVITY         | activity FIT                         |
| 128/5        | WORKOUTS         |                                      |
| 128/6        | COURSES          |                                      |
| 128/7        | SCHEDULES        |                                      |
| 128/8        | LOCATION         |                                      |
| 128/9        | WEIGHT           |                                      |
| 128/10       | TOTALS           |                                      |
| 128/11       | GOALS            |                                      |
| 128/14       | BLOOD_PRESSURE   |                                      |
| 128/15       | MONITOR_A        |                                      |
| 128/20       | SUMMARY          |                                      |
| 128/28       | MONITOR_DAILY    |                                      |
| 128/29       | RECORDS          |                                      |
| 128/31       | UNKNOWN_31       | sent by HRM Pro Plus                 |
| 128/32       | MONITOR          | the daily monitoring file            |
| 128/33       | MLT_SPORT        |                                      |
| 128/34       | SEGMENTS         |                                      |
| 128/35       | SEGMENT_LIST     |                                      |
| 128/37       | CLUBS            |                                      |
| 128/38       | SCORE            |                                      |
| 128/39       | ADJUSTMENTS      |                                      |
| 128/40       | HMD              |                                      |
| 128/41       | CHANGELOG        |                                      |
| 128/44       | METRICS          |                                      |
| 128/49       | SLEEP            |                                      |
| 128/54       | CHRONO_SHOT      | Garmin Xero C1 Pro                   |
| 128/56       | PACE_BANDS       |                                      |
| 128/57       | SPORTS_BACKUP    | Edge 530/830                         |
| 128/58       | DEVICE_58        | "Device" on Fenix 7s                 |
| 128/59       | MUSCLE_MAP       |                                      |
| 128/60       | RUNNING_TRACK    |                                      |
| 128/61       | ECG              |                                      |
| 128/62       | BENCHMARK        |                                      |
| 128/63       | POWER_GUIDANCE   |                                      |
| 128/65       | CALENDAR         |                                      |
| 128/68       | HRV_STATUS       |                                      |
| 128/70       | HSA              |                                      |
| 128/71       | COM_ACT          |                                      |
| 128/72       | FBT_BACKUP       |                                      |
| 128/73       | SKIN_TEMP        |                                      |
| 128/74       | FBT_PTD_BACKUP   |                                      |
| 128/77       | SCHEDULE         |                                      |
| 128/79       | SLP_DISR         |                                      |
| 255/4        | DOWNLOAD_COURSE  | uploadable                           |
| 255/17       | PRG              | Connect IQ binaries                  |
| 255/244      | IQ_ERROR_REPORTS |                                      |
| 255/245      | ERROR_SHUTDOWN_REPORTS |                                |
| 255/246      | GOLF_SCORECARD   | vivoactive 5                         |
| 255/247      | ULF_LOGS         |                                      |
| 255/248      | KPI              | Instinct Solar Tactical Edition      |

`isFitFile()` returns true iff `type == 128`. Non-FIT files are written
to disk with `.bin` extension, FIT files with `.fit`.

The naming convention on disk is
`<FILETYPE>/<yyyy>/<FILETYPE>_<yyyy-MM-dd_HH-mm-ss>_<fileIndex>.<ext>`
(`FileTransferHandler.DirectoryEntry.getOutputPath()`,
lines 468–483).

---

## 6. File Download (Watch → Phone)

Per-file download is the same flow as the directory file:

```
PHONE → DownloadRequestMessage(5002, fileIndex=N, dataOffset=0, NEW, 0, 0)
WATCH → DownloadRequestStatusMessage(ACK, OK, maxFileSize)
WATCH → FileTransferDataMessage(5004) × N   (per-chunk: phone ACKs each)
PHONE  ── full file in buffer; saveFileToExternalStorage()
PHONE → SetFileFlagsMessage(5008, fileIndex=N, ARCHIVE)   if !keepActivityDataOnDevice
```

A few details worth highlighting:

### 6.1 Resume / partial download

`DownloadRequestMessage` includes `requestType` (`CONTINUE` / `NEW`),
`dataOffset`, `crcSeed` and `dataSize`. Gadgetbridge in current master
**always sends NEW** (`FileTransferHandler.java:121, 126, 134`), but the
wire protocol supports resume:

- `requestType = CONTINUE (0)`
- `dataOffset = bytes already on phone`
- `crcSeed = running CRC of those bytes` (the same Garmin CRC-16 used
  for the GFDI frame)
- `dataSize = remaining bytes to send`, or 0 for "to end".

If you implement resume on iOS, you'll need to keep the running CRC
across reconnects (it's not in the directory entry).

### 6.2 Failure handling

`DownloadRequestStatusMessage.canProceed()` returns false if status≠ACK
or downloadStatus≠OK. In that case
`Download.processDownloadRequestStatusMessage` emits a
`FileDownloadedDeviceEvent(success=false)` and clears
`currentlyDownloading`. The download queue then advances to the next
file (`FileTransferHandler.java:178–191`,
`GarminSupport.java:447–454`).

There is no retry of an individual file on failure — the file is just
skipped. Per-chunk retry is also absent: a CRC or offset mismatch
throws `IllegalStateException` from
`FileFragment.append()`, which propagates up through `onMessage()` and
typically tears down the link (Android catches and logs).

### 6.3 Where files end up

`FileTransferHandler.Download.saveFileToExternalStorage()`
(lines 193–212) writes to
`<exportDir>/<DirectoryEntry.getOutputPath()>` then sets
`outputFile.setLastModified(directoryEntry.fileDate.getTime())`. The
file is then registered in the GB DB as a `PendingFile`
(`GarminSupport.java:462–470`); the `FitAsyncProcessor` consumes
pending FIT files at the end of `processDownloadQueue()`
(`GarminSupport.java:950–964`).

### 6.4 Auto-archive

Unless the user pref `keep_activity_data_on_device` is on, every
successful download is followed by a `SetFileFlagsMessage(fileIndex,
ARCHIVE)` (id 5008) — see §9. The watch typically deletes the file
on next sweep, so you don't re-download the same activity twice.

---

## 7. Per-Chunk CRC and the Running CRC State

The 2-byte `crc` field inside each `FileTransferDataMessage` is **not**
the CRC of just that chunk — it is the **running CRC of the whole file
so far**, *including* the bytes in this chunk:

```java
// FileTransferHandler.java:392–399  (FileFragment.append)
final int dataCrc = ChecksumCalculator.computeCrc(
        getRunningCrc(),
        fileTransferDataMessage.getMessage(), 0, fileTransferDataMessage.getMessage().length);
if (fileTransferDataMessage.getCrc() != dataCrc)
    throw new IllegalStateException("Received message with invalid CRC");
setRunningCrc(dataCrc);
```

`ChecksumCalculator.computeCrc(int seed, byte[] data, int off, int len)`
is the same Garmin CRC-16 variant used for the outer GFDI frame (see
the pairing doc, §6). The seed for the first chunk is **0**.

For uploads, the phone computes the same way:
```java
// FileTransferHandler.java:401–407 (FileFragment.take)
setRunningCrc(ChecksumCalculator.computeCrc(getRunningCrc(), chunk, 0, chunk.length));
return new FileTransferDataMessage(chunk, currentOffset, getRunningCrc());
```

This means the per-chunk CRC is **always cumulative** — if you reorder
or drop a chunk, the next CRC won't match.

---

## 8. File Upload (Phone → Watch)

The upload FSM is the symmetric counterpart of download, but starts
with a `CreateFile` handshake to allocate a slot.

### 8.1 Trigger

Uploads are kicked off from:
- `onSetAlarms` — alarms are encoded as a synthetic FIT file and uploaded
  as `SETTINGS` (`GarminSupport.java:1014–1104`).
- `onInstallApp` — fit/gpx/prg files dropped by the user
  (`GarminSupport.java:1328–1362`). FIT and PRG are uploaded with their
  declared type; GPX is converted to a FIT course via
  `GpxRouteFileConverter` and uploaded as a course-typed FIT.
- Weather sends use `FitLocalMessageHandler` which uses
  `FitDefinition`/`FitData` messages (5011/5012) instead of the
  CreateFile path — see §10.4.

All these reduce to:

```java
// FileTransferHandler.java:138–141  (initiateUpload)
public CreateFileMessage initiateUpload(byte[] fileAsByteArray, FileType.FILETYPE filetype) {
    upload.setCurrentlyUploading(new FileFragment(
        new DirectoryEntry(0, filetype, 0, 0, 0, fileAsByteArray.length, null), fileAsByteArray));
    return new CreateFileMessage(fileAsByteArray.length, filetype);
}
```

### 8.2 `CreateFileMessage` (id 5005) wire format

```java
// messages/CreateFileMessage.java:43–60 (generateOutgoing)
writer.writeShort(0);                          // length
writer.writeShort(garminMessage.getId());      // 5005
writer.writeInt(fileSize);                     // total bytes about to upload
writer.writeByte(filetype.getType());          // 128 for FIT / 255 for other
writer.writeByte(filetype.getSubType());       // e.g. 5 for WORKOUTS
writer.writeShort(0);                          // fileIndex (let the watch assign one)
writer.writeByte(0);                           // reserved
writer.writeByte(0);                           // subtype mask
writer.writeShort(65535);                      // numbermask = 0xFFFF
writer.writeShort(0);                          // ???
writer.writeLong(random.nextLong());           // 8 random bytes
```

Total payload: 24 bytes + 2-byte CRC. The trailing random `long`
appears to be a client-supplied UUID-ish discriminator; there is a
TODO in the code admitting the variables aren't fully understood
(`messages/CreateFileMessage.java:44`).

### 8.3 `CreateFileStatusMessage` (5005 | 0x8000)

```
1 byte   status            (ACK)
1 byte   createStatus      (0=OK, 1=DUPLICATE, 2=NO_SPACE, 3=UNSUPPORTED, 4=NO_SLOTS, 5=NO_SPACE_FOR_TYPE)
2 bytes  fileIndex         (the slot the watch assigned)
1 byte   fileDataType
1 byte   fileSubType
2 bytes  fileNumber
```

`canProceed() = status==ACK && createStatus==OK` — anything else aborts
(`messages/status/CreateFileStatusMessage.java:21–51`).

### 8.4 `UploadRequestMessage` (id 5003)

If CreateFile succeeded, the phone immediately sends:

```java
// FileTransferHandler.Upload.setCreateFileStatusMessage:296
return new UploadRequestMessage(createFileStatusMessage.getFileIndex(),
                                currentlyUploading.getDataSize());
// messages/UploadRequestMessage.java:33–43 (generateOutgoing)
writer.writeShort(0);
writer.writeShort(garminMessage.getId());      // 5003
writer.writeShort(fileIndex);                  // slot from CreateFileStatus
writer.writeInt(size);                         // total bytes
writer.writeInt(dataOffset);                   // 0 for fresh upload
writer.writeShort(crcSeed);                    // 0 for fresh upload
```

Total payload: 14 bytes + CRC.

### 8.5 `UploadRequestStatusMessage` (5003 | 0x8000)

```
1 byte  status            (ACK)
1 byte  uploadStatus      (0=OK, 1=INDEX_UNKNOWN, 2=INDEX_NOT_WRITEABLE, 3=NO_SPACE_LEFT,
                           4=INVALID, 5=NOT_READY, 6=CRC_INCORRECT)
4 bytes dataOffset        (where the watch wants the next byte; must equal dataHolder.position)
4 bytes maxFileSize       (max bytes per FileTransferData chunk for this slot)
2 bytes crcSeed           (echo)
```

If `dataOffset != dataHolder.position()` Gadgetbridge throws
`IllegalStateException("Received upload request with unaligned offset")`.
Otherwise it sends the **first chunk** by calling
`currentlyUploading.take()`
(`messages/status/UploadRequestStatusMessage.java:19–48`,
`FileTransferHandler.java:304–310`).

### 8.6 The chunk loop

`FileFragment.take()` cuts a chunk of `min(remaining, maxPacketSize - 13)`
bytes (the 13 = 2 length + 2 type + 1 flags + 2 chunk-CRC + 4 offset
+ 2 frame-CRC) and emits a `FileTransferDataMessage` (5004 — same
format as the download direction; see §5.3).

The watch ACKs each chunk with `FileTransferDataStatusMessage`
(id 5000 RESPONSE wrapping 5004); on each ACK
(`FileTransferHandler.Upload.processUploadProgress`, lines 321–349):

- If `dataSize <= dataOffset` → upload is **complete** → the handler
  returns `SystemEventMessage(SYNC_COMPLETE, 0)` as the followup, and
  drops `currentlyUploading`. (Yes — the followup that closes an
  upload is a `SYNC_COMPLETE` SystemEvent.)
- Otherwise if `canProceed()` → emit the next chunk via `take()`.
- Otherwise → upload aborts, progress notification is set to "failed".

### 8.7 `maxPacketSize` and the 13-byte overhead

`maxPacketSize` defaults to **375** in
`FileTransferHandler.java:62` and is updated whenever a
`MaxPacketSizeDeviceEvent` arrives
(`GarminSupport.java:441–443`). That event in turn is fired by ML
service negotiation (see pairing doc §3 / Multi-Link layer). On the
Instinct Solar 1G expect 375; on watches with larger MTU it can grow
to ~500.

The 13-byte deduction inside `FileFragment.take()` accounts for the
GFDI overhead **per `FileTransferDataMessage`**:
```
2 (size) + 2 (type) + 1 (flags) + 2 (per-chunk CRC) + 4 (dataOffset) + 2 (frame CRC) = 13
```
Don't forget the COBS overhead is on top of that, eating ~1 extra byte
per ~254-byte run plus framing zeros.

---

## 9. `SET_FILE_FLAG` — Marking Files Archived/Deleted

After a successful download — and **also** when `processDownloadQueue`
notices a directory entry that's already on disk — the phone sends
`SetFileFlagsMessage` (id 5008) with the `ARCHIVE` flag, which causes
the watch to clear it on its next sweep
(`GarminSupport.java:472–474, 876–877`):

```java
// messages/SetFileFlagsMessage.java:18–26
writer.writeShort(0);
writer.writeShort(garminMessage.getId());      // 5008
writer.writeShort(fileIndex);
writer.writeByte(EnumUtils.generateBitVector(FileFlags.class, flags));
```

`FileFlags` ordinals:

| Ordinal | Bit  | Symbol         |
|---------|------|----------------|
| 0       | 0x01 | UNK_00000001   |
| 1       | 0x02 | UNK_00000010   |
| 2       | 0x04 | UNK_00000100   |
| 3       | 0x08 | UNK_00001000   |
| 4       | 0x10 | ARCHIVE        |

`ARCHIVE` is bit 4 (0x10). Gadgetbridge always passes a single-element
EnumSet; the resulting wire byte is `0x10`.

Total payload: 7 bytes + CRC.

The watch ACKs with `SetFileFlagsStatusMessage` (5008 | 0x8000); GB
ignores the contents.

---

## 10. Other Messages That Gate or Accompany Sync

This section is intentionally brief — these messages don't block the
file sync FSM but they are exchanged on the link and you want to at
least no-op them so the watch is happy.

### 10.1 `Configuration` (id 5050)

Already covered in the pairing doc but worth restating: the watch sends
`ConfigurationMessage` (5050) carrying its capability bitmap; the phone
**must** reply with its own `ConfigurationMessage` carrying
`OUR_CAPABILITIES` (`messages/ConfigurationMessage.java:31–44`). The
inbound `ConfigurationMessage` also fires the `CapabilitiesDeviceEvent`
that triggers `completeInitialization()` (§1.1).

### 10.2 `SystemEvent` (id 5030)

```java
// messages/SystemEventMessage.java:14–28
writer.writeShort(0);
writer.writeShort(garminMessage.getId());     // 5030
writer.writeByte(eventType.ordinal());
// then either
writer.writeString((String) value);           // length-prefixed UTF-8
// or
writer.writeByte((Integer) value);            // single byte
```

Event types and ordinals (`messages/SystemEventMessage.java:30–48`):

| Ordinal | Symbol                           |
|---------|----------------------------------|
| 0       | SYNC_COMPLETE                    |
| 1       | SYNC_FAIL                        |
| 2       | FACTORY_RESET                    |
| 3       | PAIR_START                       |
| 4       | PAIR_COMPLETE                    |
| 5       | PAIR_FAIL                        |
| 6       | HOST_DID_ENTER_FOREGROUND        |
| 7       | HOST_DID_ENTER_BACKGROUND        |
| 8       | SYNC_READY                       |
| 9       | NEW_DOWNLOAD_AVAILABLE           |
| 10      | DEVICE_SOFTWARE_UPDATE           |
| 11      | DEVICE_DISCONNECT                |
| 12      | TUTORIAL_COMPLETE                |
| 13      | SETUP_WIZARD_START               |
| 14      | SETUP_WIZARD_COMPLETE            |
| 15      | SETUP_WIZARD_SKIPPED             |
| 16      | TIME_UPDATED                     |

For all SystemEvents that GB sends, `value` is always `0` (Integer),
giving a 6-byte payload (length-2, type-2, eventType-1, value-1) +
2-byte CRC = 8 bytes on the wire.

### 10.3 `DeviceSettings` (id 5026)

```java
// messages/SetDeviceSettingsMessage.java:18–39
writer.writeShort(0);
writer.writeShort(garminMessage.getId());     // 5026
writer.writeByte(settings.size());
for (entry in settings) {
    writer.writeByte(setting.ordinal());
    if (value instanceof String)  writer.writeString(value);          // length byte + UTF-8
    else if (value instanceof Integer) { writer.writeByte(4); writer.writeInt(value); }
    else if (value instanceof Boolean) { writer.writeByte(1); writer.writeByte(b ? 1 : 0); }
}
```

Setting ordinals:

| Ordinal | Symbol                           |
|---------|----------------------------------|
| 0       | DEVICE_NAME                      |
| 1       | CURRENT_TIME                     |
| 2       | DAYLIGHT_SAVINGS_TIME_OFFSET     |
| 3       | TIME_ZONE_OFFSET                 |
| 4       | NEXT_DAYLIGHT_SAVINGS_START      |
| 5       | NEXT_DAYLIGHT_SAVINGS_END        |
| 6       | AUTO_UPLOAD_ENABLED              |
| 7       | WEATHER_CONDITIONS_ENABLED       |
| 8       | WEATHER_ALERTS_ENABLED           |

`completeInitialization()` only sends 6, 7, 8 (each Boolean), so the
typical first-connect frame is 14 bytes of payload + CRC.

### 10.4 `WeatherMessage` (id 5014, watch → phone)

Watch sends:

```
1 byte    format
4 bytes   latitude   (semicircles? semantics not nailed down by GB)
4 bytes   longitude
1 byte    hoursOfForecast
```

(`messages/WeatherMessage.java:19–26`). GB just unpacks into a
`WeatherRequestDeviceEvent`, then `evaluateGBDeviceEvent` calls
`sendWeatherConditions()` which encodes a FIT weather record via
`FitLocalMessageBuilder`/`FitLocalMessageHandler` and sends it as a
**`FIT_DEFINITION` (5011) followed by `FIT_DATA` (5012)** pair on the
link. (Not a file upload — it's pushed inline as a FIT local message.)

This is the only path on the link that uses the local-FIT subprotocol
(`FitLocalMessageHandler.java:39–47`). For an iOS port that doesn't
need to send weather, you can ignore 5011/5012/5014 entirely.

### 10.5 `FindMyPhone` (5039) / `FindMyPhoneCancel` (5040)

Watch-initiated; trigger a tone on the phone. Independent of sync.

### 10.6 `MusicControl` family (5041, 5042, 5049)

Music remote control. Independent of sync.

### 10.7 Notification family (5033, 5034, 5035, 5036)

Notifications. Independent of sync but the watch will subscribe via
`NotificationSubscription` (5036) post-pairing. If you don't implement
notifications, you can NAK these and the watch will still let you
sync.

### 10.8 `Protobuf` (5043 / 5044)

Two-way envelope for the modern protobuf services
(`GdiSmartProto.Smart`). Used for: battery status, FindMyWatch,
RealtimeSettings, AppList, AppConfig, the new FileSync service (§11),
and more. If you don't intend to implement any protobuf-backed feature,
you can ignore — the legacy file sync still works without them.

---

## 11. The "New Sync Protocol" (`FileSyncService`)

Newer Garmin watches (anything modern enough to advertise the
`FileSyncService` protobuf) prefer to enumerate files via protobuf
rather than 16-byte directory rows. Gadgetbridge supports both, gated
by the per-device pref `new_sync_protocol`
(`GarminSupport.newSyncProtocol()`, line 534).

When `newSyncProtocol()` is true, `parseDirectoryEntries` short-circuits
after receiving the root directory and instead asks for a file list via
protobuf:

```java
// FileTransferHandler.java:214–221
if (deviceSupport.newSyncProtocol()) {
    deviceSupport.addFileToDownloadList(currentlyDownloading.directoryEntry);
    return;
}
```

```java
// GarminSupport.java:222–235 (addFileToDownloadList for DirectoryEntry)
if (newSyncProtocol() && directoryEntry.getFiletype() != FILETYPE.DEVICE_XML) {
    if (directoryEntry.getFiletype() == FILETYPE.DIRECTORY) {
        sendOutgoingMessage("request file list",
            protocolBufferHandler.prepareProtobufRequest(
                GdiSmartProto.Smart.newBuilder().setFileSyncService(
                    protocolBufferHandler.getFileSyncServiceHandler().requestFileList()
                ).build()));
        return;
    }
    return;
}
```

The phone then exchanges:
- `FileSyncService.FileListRequest` (page-paginated)
- `FileSyncService.FileListResponse` (list of `File` records with id1/id2)
- `FileSyncService.FileRequest` per file
- `FileSyncService.FileResponse` carrying a `handle` int
- `FileSyncService.NewFileNotification` (watch-initiated when new files appear)

The actual file bytes do **not** travel inside the protobuf envelope —
the watch returns a `handle` and the phone opens a Multi-Link
**service** (different `serviceId`) to stream the bytes. See
`GarminSupport.downloadFileFromServiceV2` (lines 1379–1490), which
opens a `CommunicatorV2.startTransfer(...)` callback channel, writes a
6-byte request `{0x00, 0x00, fileHandle (LE 16), 0x00, 0x00}`, buffers
the streamed reply, then `CompressionUtils.inflate()`s it (the file is
zlib-compressed in this transport), writes the inflated bytes to disk
and runs `FitImporter` on it.

After a successful new-protocol download, the phone sends a
`FileSyncService.SyncedCommand` (via the protobuf envelope) to mark the
file as synced — equivalent to the legacy `SetFileFlagsMessage(ARCHIVE)`
(`GarminSupport.java:1451–1462`).

For an iOS implementation aiming at the Instinct Solar 1G, you can
**skip this whole section** — the Instinct doesn't speak FileSyncService
and the legacy 5002/5004 path works.

---

## 12. GFDI Message Type Catalog

All IDs from `messages/GFDIMessage.java:92–143` (the
`GarminMessage` enum). The pairing doc already covered the common
header conventions (length, `& 0x8000` compact-status encoding, CRC
variant); this table is just the sync-relevant subset annotated with
direction and one-line purpose. **Decimal IDs.**

| ID    | Symbol                           | Direction | Purpose                                                    |
|-------|----------------------------------|-----------|------------------------------------------------------------|
| 5000  | RESPONSE (a.k.a. GFDIStatus)     | both      | Generic ACK/status. Body: 2-byte responding-to id, 1-byte status, then optional message-specific payload. Also sent compact-typed when piggy-backed via `& 0x8000`. |
| 5002  | DOWNLOAD_REQUEST                 | phone→watch | Begin/continue download of file at `fileIndex`            |
| 5003  | UPLOAD_REQUEST                   | phone→watch | After CreateFile ACK; ask to start streaming chunks      |
| 5004  | FILE_TRANSFER_DATA               | both      | One chunk of file bytes (per-chunk running CRC)            |
| 5005  | CREATE_FILE                      | phone→watch | Allocate a slot for an upload of given type/size         |
| 5007  | FILTER                           | phone→watch | Hard-coded `byte 3`; consent to a watch-initiated sync   |
| 5008  | SET_FILE_FLAG                    | phone→watch | Mark a file ARCHIVE (or other flags) — used to delete    |
| 5011  | FIT_DEFINITION                   | phone→watch | Local FIT definition record (used by inline FIT pushes)   |
| 5012  | FIT_DATA                         | phone→watch | Local FIT data record matching a 5011                     |
| 5014  | WEATHER_REQUEST                  | watch→phone | Watch asks for weather                                   |
| 5024  | DEVICE_INFORMATION               | watch→phone first, phone→watch reply | First message after auth; protocol/firmware/device ID exchange |
| 5026  | DEVICE_SETTINGS                  | phone→watch | Push key/value device settings                            |
| 5030  | SYSTEM_EVENT                     | both      | Lifecycle pokes: SYNC_READY, SYNC_COMPLETE, TIME_UPDATED, etc. |
| 5031  | SUPPORTED_FILE_TYPES_REQUEST     | phone→watch | Request the watch's list of supported file types         |
| 5033  | NOTIFICATION_UPDATE              | phone→watch | (notifications) replaces an existing notification         |
| 5034  | NOTIFICATION_CONTROL             | watch→phone | (notifications) user action on watch                     |
| 5035  | NOTIFICATION_DATA                | phone→watch | (notifications) push a new notification                  |
| 5036  | NOTIFICATION_SUBSCRIPTION        | watch→phone | (notifications) watch enables/disables notification stream |
| 5037  | SYNCHRONIZATION                  | watch→phone | Watch announces "I have data of these types, sync me"   |
| 5039  | FIND_MY_PHONE_REQUEST            | watch→phone | Trigger phone alarm                                       |
| 5040  | FIND_MY_PHONE_CANCEL             | watch→phone | Stop phone alarm                                          |
| 5041  | MUSIC_CONTROL                    | watch→phone | Music transport command                                   |
| 5042  | MUSIC_CONTROL_CAPABILITIES       | watch→phone | Music capabilities exchange                              |
| 5043  | PROTOBUF_REQUEST                 | both      | Protobuf envelope (req side)                              |
| 5044  | PROTOBUF_RESPONSE                | both      | Protobuf envelope (resp side)                             |
| 5049  | MUSIC_CONTROL_ENTITY_UPDATE      | phone→watch | Music metadata push                                      |
| 5050  | CONFIGURATION                    | both      | Capability bitmap exchange (covered by pairing doc; emits CapabilitiesDeviceEvent that triggers `completeInitialization()`) |
| 5052  | CURRENT_TIME_REQUEST             | watch→phone | Watch asks "what time is it now?"                        |
| 5101  | AUTH_NEGOTIATION                 | watch→phone | Auth-flag negotiation; phone replies with all-zero flags |

Note that the phone-side reply to many of the above is a `5000`
(`RESPONSE`) frame whose body starts with the 2-byte responding-to id —
i.e. the watch sees `5000 / 5052` to mean "ACK of 5052". The
status/ACK frames in the `messages/status/` package all encode this way
**unless** sent compact-typed via `& 0x8000`.

---

## 13. Concrete Hex-Dump Examples

These are the **GFDI payload** bytes (length+type+body+CRC) in the
order they arrive at the GFDI layer — i.e. *before* COBS framing and
*after* COBS de-framing on the receive side. Refer to the pairing doc
§3–6 for COBS and Multi-Link wrappers.

All multi-byte integers are little-endian.

### Example 1 — Phone responds to `CURRENT_TIME_REQUEST`

Inbound frame (watch → phone):

```
13 00              len = 0x0013 (19 bytes total)
14 14              type = 0x1414 = 5140?  no — 5052 dec = 0x14 0x9C... wait, see note
4F 02 00 00        referenceID = 0x0000024F = 591
xx xx              CRC
```

> **Note on the type encoding.** 5052 decimal = 0x13BC, so the on-wire
> bytes are `BC 13`. The example above shows the *decimal-id* mistake
> commonly made when first reading the code; verify against
> `GarminMessage.fromId()` which compares the integer 5052, not 0x14.
> Corrected:

```
13 00            len = 19
BC 13            type = 5052  (CURRENT_TIME_REQUEST)
4F 02 00 00      referenceID = 591
xx xx            CRC-16 (Garmin variant, see pairing doc §6)
```

Outbound reply (phone → watch); 25 bytes of payload + 2 of CRC:

```
19 00            len = 25
88 13            type = 5000  (RESPONSE)
BC 13            responding-to = 5052
00               status = ACK
4F 02 00 00      referenceID echo = 591
80 25 92 4F      garminTimestamp (e.g. 0x4F922580 = 1335931776 → unix 1966997376)
00 1C 00 00      timeZoneOffset = 7200 (+02:00, in seconds)
00 00 00 00      nextTransitionEnds = 0  (no upcoming transition)
00 00 00 00      nextTransitionStarts = 0
xx xx            CRC
```

(The exact `garminTimestamp` value depends on wall clock; the example
above corresponds to a moment in roughly 2032 — pick one that matches
your test instant.)

### Example 2 — Phone requests the root directory

GFDI payload (21 bytes including CRC):

```
13 00            len = 19
8A 13            type = 5002  (DOWNLOAD_REQUEST)
00 00            fileIndex = 0  (root directory)
00 00 00 00      dataOffset = 0
01               requestType = NEW
00 00            crcSeed = 0
00 00 00 00      dataSize = 0  (i.e. "send everything")
xx xx            CRC
```

Watch's reply (8 bytes payload + CRC), compact-typed:

```
0C 00            len = 12
8A 93            type = (5002 | 0x8000) | seq = 0x938A — NB compact-type encodes as
                  ((messageType - 5000) | 0x8000) | (seq << 8). MessageReader unwraps:
                  raw = 0x938A; (raw & 0x8000)!=0 → type = (raw & 0xFF) + 5000 = 0x8A + 5000 = 5138?
                  See note below.
00               status = ACK
00               downloadStatus = OK
40 02 00 00      maxFileSize = 0x240 = 576
xx xx            CRC
```

> **Important correction.** Re-reading
> `GFDIMessage.parseIncoming` (lines 31–36):
> ```java
> if ((messageType & 0x8000) != 0) {
>     messageType = (messageType & 0xff) + 5000;
> }
> ```
> Only the **low byte** is added to 5000. So a compact-type frame for
> `DOWNLOAD_REQUEST_STATUS` (the status of 5002) carries low byte =
> 5002 - 5000 = 0x02 → wire = `0x02 | 0x8000 | (seq << 8)`. With seq=0,
> bytes are **`02 80`**. The example bytes above should be:
>
> ```
> 0C 00            len = 12
> 02 80            type compact: seq=0, low=0x02 → 5002 status
> 00               status = ACK
> 00               downloadStatus = OK
> 40 02 00 00      maxFileSize = 576
> xx xx            CRC
> ```
>
> (The pairing doc's §7 spells this out in more detail.)

### Example 3 — A single 64-byte file-transfer chunk

Watch → phone, mid-download:

```
4F 00                            len = 79  (= 2 + 2 + 1 + 2 + 4 + 64 + 2 + 2)
8C 13                            type = 5004
00                               flags = 0
A3 4C                            chunkCRC (running) = 0x4CA3
80 01 00 00                      dataOffset = 384  (this chunk starts at byte 384 of the file)
0E 10 D2 04 …  (64 raw bytes)    payload (FIT-format bytes, opaque at this layer)
xx xx                            GFDI CRC
```

Phone's per-chunk ACK (sent immediately by `sendAck(...)`); compact-typed:

```
0A 00            len = 10
04 80            compact-type, low=0x04 (status of 5004), seq=0
00               status = ACK
00               transferStatus = OK
C0 01 00 00      dataOffset = 448  (next byte the phone expects = 384 + 64)
xx xx            CRC
```

The `dataOffset` field is what makes flow control possible: the watch
doesn't proceed past `448` until it has seen this ACK. Notice it is
**not** wrapped as a `5000 RESPONSE` here because of the compact
encoding — the receive code path doesn't care which form it gets.
(For uploads, see `FileTransferDataStatusMessage.generateOutgoing`,
which uses the explicit `5000 RESPONSE` form,
`messages/status/FileTransferDataStatusMessage.java:48–58`.)

---

## 14. iOS Implementation Guidance and Known Unknowns

### 14.1 Straightforward to port

- **The whole legacy file-sync FSM.** Five message types
  (5002/5003/5004/5005/5007/5008) plus one status per direction. The
  state is per-fragment (offset + running CRC + max size), no
  multi-file pipelining: at most one download and at most one upload
  in flight.
- **Time sync.** Receive 5052, immediately reply with a 5000 RESPONSE
  containing the 5-int payload. There is no clock state to maintain.
  Send a `SystemEvent(TIME_UPDATED, 0)` whenever the iOS app is
  informed of a clock change (`UIApplication.significantTimeChange`
  notification, or a TZ change from `NSSystemTimeZoneDidChange`).
- **Directory enumeration.** Identical to file download; just parse
  16-byte rows when the file completes.
- **CRC.** Same Garmin CRC-16 variant as the GFDI frame (pairing doc
  §6). Reuse the same routine for both the frame CRC and the per-chunk
  running CRC.
- **`SystemEvent` always-zero values.** All current emit sites pass
  `Integer 0`, giving an 8-byte frame. The `Object value` polymorphism
  in `SystemEventMessage` is unused in practice.

### 14.2 Worth being careful about

- **Compact-type encoding (`& 0x8000`).** Every status frame can come
  back two ways: explicit `5000 RESPONSE` wrapping the responded-to
  type, **or** compact-typed where the type field has the high bit set
  and only the low byte + 5000 is the real id. Your decoder must check
  `& 0x8000` on the **type word** (not the length) and unwrap. See
  `GFDIMessage.parseIncoming` (lines 31–36). The pairing doc §7
  expands on this.
- **`maxPacketSize` per-slot.** It defaults to 375 but can change.
  iOS's `peripheral.maximumWriteValueLength(for: .withoutResponse)` is
  the analogue, but Garmin's value is the **GFDI** payload max — not
  the ATT MTU. Allocate chunks of `maxPacketSize - 13` bytes for
  uploads (see §8.7).
- **Per-chunk running CRC.** It is **not** the CRC of the chunk; it is
  the CRC of *all bytes received so far*. Easy to get wrong. Test by
  diffing your CRC sequence against a real watch's reported values
  during a download.
- **Directory-entry timestamp uses Garmin epoch.** Convert via
  `unixSeconds = garminTs + 631065600`. Same for the timestamp returned
  in `CURRENT_TIME_REQUEST`'s response.
- **Two output sender slots in the receive pump.** A handler can return
  a *followup*; the inbound message can also generate its own *reply*
  (e.g. `CurrentTimeRequestMessage.generateOutgoing()` writes a 5000
  reply directly inside its outgoing serializer). If you collapse
  these into one path, you'll either drop the time-sync reply or send
  two ACKs for the same inbound frame. The order on the wire is **ack
  → reply → followup**, see `GarminSupport.onMessage` lines 355–359.
- **`completeInitialization()` is gated on the inbound
  `ConfigurationMessage`.** Don't try to start sync until you've seen a
  5050 from the watch and replied with your own 5050 carrying
  `OUR_CAPABILITIES`. Otherwise the watch may not honour
  `SUPPORTED_FILE_TYPES_REQUEST`.
- **Watch-initiated sync vs phone-initiated fetch.** Both end up at the
  same root-directory `DownloadRequestMessage`, but they enter the
  state machine at different points. In particular, the watch-initiated
  path requires you to first send a `FilterMessage(byte 3)` and wait
  for its `FilterStatusMessage` ACK before requesting the directory.
  If you skip the filter step, modern firmware tends to silently drop
  the subsequent download request.
- **First connect's `mFirstConnect` triplet.** `PAIR_COMPLETE`,
  `SYNC_COMPLETE`, `SETUP_WIZARD_COMPLETE` are sent **only** the first
  time the device pairs. Setting `mFirstConnect=true` on subsequent
  connects will confuse the watch (it'll re-run setup). On iOS, you
  need to persist this flag across app launches — keying on the
  watch's serial / unit number returned in `DeviceInformationMessage`
  is appropriate (`DeviceInformationMessage.java:51–61`).
- **The CreateFile "random long".** GB writes 8 random bytes at the
  end of the `CreateFileMessage` payload
  (`CreateFileMessage.java:57`) with a TODO note that the variables
  aren't fully understood. Mirror the random bytes; do not assume zero
  works. There is no known protocol-level penalty for a bad value, but
  GB's behaviour is what's been validated in the wild.
- **Per-chunk ACK is mandatory.** The `sendAck` in the receive pump
  fires for every inbound message — including each
  `FileTransferDataMessage`. If you only ack at end-of-file, the watch
  will pause indefinitely (it tracks the `dataOffset` in your ACK as
  the resume cursor).

### 14.3 What you can skip on iOS

- **Notifications (5033/5034/5035/5036).** A watch will sync activity
  files happily without ever subscribing to notifications. NAK or
  ignore.
- **Music control (5041/5042/5049).** Same.
- **FindMyPhone (5039/5040).** Same.
- **Protobuf services (5043/5044) entirely.** The legacy file-sync
  flow does not require protobuf. Battery, FindMyWatch, AppList, etc.
  are all protobuf-only.
- **The "new sync protocol" (FileSyncService).** Not used on Instinct
  Solar 1G; only modern protobuf-aware watches use it.
- **Inline FIT push (5011/5012).** Only used for weather. If you're
  not pushing weather, the watch will not initiate this direction.
- **MultiLink-Reliable (MLR).** GB uses basic ML for GFDI by default;
  MLR is opt-in via the `garmin_mlr` pref (`GarminSupport.java:538–540`).
  Stick with basic ML.
- **Fenix-class-only file types.** The
  `FileType.FILETYPE` enum lists every type any Garmin watch is known
  to expose. You only need to recognise the ones in
  `FILE_TYPES_TO_PROCESS` (DIRECTORY, ACTIVITY, MONITOR, METRICS,
  CHANGELOG, HRV_STATUS, SLEEP, SKIN_TEMP) to do useful sync. Other
  types appear in directory listings but you can skip them.
- **CommunicatorV1.** GB carries a V1 fallback for older Garmin
  hardware (the `…2300` family); Instinct Solar 1G is V2. iOS port
  can target V2 only.

### 14.4 Known unknowns / gaps in this doc

- **`SynchronizationType` enum semantics.** `TYPE_0`, `TYPE_1`,
  `TYPE_2` are emitted by the watch but their meaning isn't documented
  by GB. `shouldProceed()` doesn't even look at the type, only at the
  bitmask.
- **`FilterType` enum semantics.** GB always sends `UNK_3 = 3`. The
  other values 0/1/2 are never sent.
- **`DownloadRequestMessage` opaque fields used during resume.** Not
  exercised by GB (it always sends `NEW`); the wire fields are present
  but the watch's behaviour with non-zero `dataOffset/crcSeed/dataSize`
  is undocumented.
- **CreateFile trailing 12 bytes.** `subtypeMask`, `numberMask`,
  trailing zero short, and 8-byte random are all marked "???" / TODO
  in source. They're necessary on the wire but their meaning isn't
  documented.
- **`AuthFlags` bits.** All marked `UNK_*` in the enum
  (`AuthNegotiationMessage.java:46–55`); GB always replies with all
  zeros and that is sufficient for current firmware.
- **`SetFileFlagsMessage` flags 0..3.** Only `ARCHIVE` (bit 4) is
  documented and used. The lower bits are wire-allowed but their
  effect is unknown.
- **Whether the per-chunk ACK's `dataOffset` is checked by all
  firmware as "next byte expected" or as "last byte received".** The
  GB code populates it as `dataOffset + message.length` in the ack
  (`FileTransferDataMessage.java:22–28`), which is "next byte
  expected"; this works in practice on all tested watches but the
  protocol spec is not in the GB tree.
- **The exact `ChecksumCalculator.computeCrc` polynomial.** Documented
  in the pairing doc §6; not repeated here. If you re-derive it on
  iOS, test against the worked examples in this doc and against a
  real watch's frames.

---

## Appendix A — File:line index of the symbols cited

| Symbol                                    | File:line                                                                                |
|-------------------------------------------|------------------------------------------------------------------------------------------|
| `GarminSupport.completeInitialization`    | `service/devices/garmin/GarminSupport.java:789–818`                                       |
| `GarminSupport.onMessage`                 | `service/devices/garmin/GarminSupport.java:326–367`                                       |
| `GarminSupport.evaluateGBDeviceEvent`     | `service/devices/garmin/GarminSupport.java:389–501`                                       |
| `GarminSupport.processDownloadQueue`      | `service/devices/garmin/GarminSupport.java:843–966`                                       |
| `GarminSupport.alreadyDownloaded`         | `service/devices/garmin/GarminSupport.java:1173–1216`                                     |
| `GarminSupport.sendDeviceSettings`        | `service/devices/garmin/GarminSupport.java:980–986`                                       |
| `GarminSupport.onSetTime`                 | `service/devices/garmin/GarminSupport.java:988–991`                                       |
| `GarminSupport.onFetchRecordedData`       | `service/devices/garmin/GarminSupport.java:511–532`                                       |
| `GarminSupport.onSetAlarms`               | `service/devices/garmin/GarminSupport.java:1014–1104`                                     |
| `GarminSupport.onInstallApp`              | `service/devices/garmin/GarminSupport.java:1328–1362`                                     |
| `GarminSupport.downloadFileFromServiceV2` | `service/devices/garmin/GarminSupport.java:1379–1490`                                     |
| `FileTransferHandler` (whole)             | `service/devices/garmin/FileTransferHandler.java`                                         |
| `FILE_TYPES_TO_PROCESS`                   | `service/devices/garmin/FileTransferHandler.java:64–73`                                   |
| `FileTransferHandler.handle`              | `service/devices/garmin/FileTransferHandler.java:93–110`                                  |
| `FileTransferHandler.initiateDownload`    | `service/devices/garmin/FileTransferHandler.java:124–127`                                 |
| `FileTransferHandler.initiateUpload`      | `service/devices/garmin/FileTransferHandler.java:138–141`                                 |
| `FileTransferHandler.parseDirectoryEntries` | `service/devices/garmin/FileTransferHandler.java:214–256`                               |
| `FileFragment.append`                     | `service/devices/garmin/FileTransferHandler.java:389–399`                                 |
| `FileFragment.take`                       | `service/devices/garmin/FileTransferHandler.java:401–407`                                 |
| `Upload.setCreateFileStatusMessage`       | `service/devices/garmin/FileTransferHandler.java:290–302`                                 |
| `Upload.setUploadRequestStatusMessage`    | `service/devices/garmin/FileTransferHandler.java:304–319`                                 |
| `Upload.processUploadProgress`            | `service/devices/garmin/FileTransferHandler.java:321–349`                                 |
| `DirectoryEntry.getOutputPath`            | `service/devices/garmin/FileTransferHandler.java:468–483`                                 |
| `GarminMessage` enum                      | `service/devices/garmin/messages/GFDIMessage.java:92–143`                                 |
| `GFDIMessage.parseIncoming`               | `service/devices/garmin/messages/GFDIMessage.java:27–50`                                  |
| `GFDIMessage.addLengthAndChecksum`        | `service/devices/garmin/messages/GFDIMessage.java:87–90`                                  |
| `MessageReader` ctor / CRC check          | `service/devices/garmin/messages/GFDIMessage.java:164–196`                                |
| `MessageWriter.writeString` (1-byte len)  | `service/devices/garmin/messages/MessageWriter.java:55–62`                                |
| `DownloadRequestMessage`                  | `service/devices/garmin/messages/DownloadRequestMessage.java`                             |
| `UploadRequestMessage`                    | `service/devices/garmin/messages/UploadRequestMessage.java`                               |
| `CreateFileMessage`                       | `service/devices/garmin/messages/CreateFileMessage.java`                                  |
| `FileTransferDataMessage`                 | `service/devices/garmin/messages/FileTransferDataMessage.java`                            |
| `SetFileFlagsMessage`                     | `service/devices/garmin/messages/SetFileFlagsMessage.java`                                |
| `FilterMessage`                           | `service/devices/garmin/messages/FilterMessage.java`                                      |
| `SynchronizationMessage`                  | `service/devices/garmin/messages/SynchronizationMessage.java`                             |
| `SupportedFileTypesMessage`               | `service/devices/garmin/messages/SupportedFileTypesMessage.java`                          |
| `SupportedFileTypesStatusMessage`         | `service/devices/garmin/messages/status/SupportedFileTypesStatusMessage.java`             |
| `SetDeviceSettingsMessage` + enum         | `service/devices/garmin/messages/SetDeviceSettingsMessage.java`                           |
| `CurrentTimeRequestMessage` (response builder) | `service/devices/garmin/messages/CurrentTimeRequestMessage.java`                     |
| `SystemEventMessage` + enum               | `service/devices/garmin/messages/SystemEventMessage.java`                                 |
| `WeatherMessage`                          | `service/devices/garmin/messages/WeatherMessage.java`                                     |
| `ConfigurationMessage`                    | `service/devices/garmin/messages/ConfigurationMessage.java`                               |
| `AuthNegotiationMessage`                  | `service/devices/garmin/messages/AuthNegotiationMessage.java`                             |
| `DownloadRequestStatusMessage`            | `service/devices/garmin/messages/status/DownloadRequestStatusMessage.java`                |
| `UploadRequestStatusMessage`              | `service/devices/garmin/messages/status/UploadRequestStatusMessage.java`                  |
| `CreateFileStatusMessage`                 | `service/devices/garmin/messages/status/CreateFileStatusMessage.java`                     |
| `FileTransferDataStatusMessage`           | `service/devices/garmin/messages/status/FileTransferDataStatusMessage.java`               |
| `FitLocalMessageHandler`                  | `service/devices/garmin/FitLocalMessageHandler.java`                                      |
| `FileType.FILETYPE` table                 | `service/devices/garmin/FileType.java:37–98`                                              |
| `GarminTimeUtils` (epoch)                 | `service/devices/garmin/GarminTimeUtils.java`                                             |
| `FileSyncServiceHandler` (new sync)       | `service/devices/garmin/FileSyncServiceHandler.kt`                                        |
| `FileToDownload`                          | `service/devices/garmin/FileToDownload.java`                                              |

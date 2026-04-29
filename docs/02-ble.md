# Project: Compass — Garmin BLE protocol port (CompassBLE package)

You are continuing work on the Compass iOS app. The Xcode project, data
models, FIT parser, and SwiftUI scaffolding already exist (see
docs/ARCHITECTURE.md). Your job in this pass is to fill in the CompassBLE
package with a working implementation of the Garmin BLE protocol that can:

1. Pair with a Garmin Instinct Solar watch
2. Authenticate using fake OAuth credentials (Gadgetbridge's bypass)
3. Pull FIT files from /Activity, /Monitor, /Sleep, /Metrics directories on
   the watch
4. Push course FIT files (and converted GPX → FIT) to the watch's NewFiles
   directory equivalent over BLE

No real-time data streams. No notifications, music control, or weather sync.

The implementation references Gadgetbridge's Java code as the protocol spec.
You will need to read the Gadgetbridge source carefully and translate the
protocol logic into idiomatic Swift. Do not attempt a line-for-line port —
use the protocol structure but write Swift-native code with async/await,
actors for state, and structured concurrency.

## Protocol overview

The Instinct Solar uses Garmin's newer Multi-Link Reliable (MLR) protocol
exposed over a single primary BLE service. Detection rule: if the device
advertises service UUID 6A4E2800-667B-11E3-949A-0800200C9A66, it uses this
protocol family.

### GATT services and characteristics

Primary service UUID: `6A4E2800-667B-11E3-949A-0800200C9A66`

Within this service, the Multi-Link characteristics for the modern protocol are:
- Write characteristic: `6A4E2820-667B-11E3-949A-0800200C9A66`
- Notify characteristic: `6A4E2810-667B-11E3-949A-0800200C9A66`

Two additional pairs (2821/2811 and 2822/2812) are used for other services
that we don't need for this MVP.

The presence of characteristic `6A4E2820-...` is the marker for "newer
protocol" — confirm this before proceeding with an MLR-style handshake.

### Multi-Link Reliable (MLR) framing

Every payload on the wire is wrapped in MLR framing. The first byte encodes:
- High bit (0x80): always set for MLR frames (distinguishes from legacy ML)
- Bits 4-6: handle (0-7). Different handles correspond to different services.
- Bits 0-3: high bits of request number (req_num)

The next byte encodes:
- High 2 bits: low bits of req_num
- Low 6 bits: sequence number (seq_num)

Followed by payload bytes. The `req_num` is used as an ACK cursor —
acknowledging req_num=N implicitly acknowledges all messages with seq_num < N
(with wrap-around handling).

Implementation notes:
- Maintain per-handle inbound and outbound queues
- A complete logical message can span multiple BLE notifications;
  reassemble fragments by handle until a complete GFDI packet is recovered
- Send periodic ACKs for received fragments
- Handle retransmission requests when the peer's req_num cursor lags

### Handle management

Handle 0 is reserved for Multi-Link control:
- Service registration query (find which services the watch supports)
- Service open/close

Other handles (assigned dynamically by the watch) correspond to services like
GFDI, registration, real-time HR, etc. For our purposes:
- Open a handle for the GFDI service
- Use it for all file transfer

### GFDI (Garmin Fit Data Interface)

GFDI is the message-oriented protocol carried over a Multi-Link handle.
GFDI messages have structure:
- 2 bytes: little-endian length (of the entire message including this field)
- 2 bytes: little-endian message type. High bit (0x8000) indicates a
  response. The message type 0x5000 is added when responding.
- Variable: payload (specific to message type)
- 2 bytes: CRC

Key message types we need to implement:
- 5024 (DEVICE_INFORMATION_REQUEST) — sent by watch on connect
- 5023 (DEVICE_INFORMATION_RESPONSE) — we send, identifying ourselves
- 5031 (CONFIGURATION) — capabilities exchange
- 5004 (FILE_LIST_REQUEST) — request directory listing
- 5005 (FILE_LIST_RESPONSE) — directory listing returned
- 5007 (DOWNLOAD_REQUEST) — request a file by index
- 5008 (DOWNLOAD_RESPONSE) — chunked file content
- 5009 (UPLOAD_REQUEST) — initiate upload
- 5010 (UPLOAD_RESPONSE) — chunk acknowledgement
- 5011 (CREATE_FILE_REQUEST)
- 5012 (CREATE_FILE_RESPONSE)
- 5014 (FIT_DEFINITION) — used during data transfer for some file types
- 5015 (FIT_DATA)
- 5022 (PROTOBUF_REQUEST) — used for OAuth, settings, etc.
- 5023 (PROTOBUF_RESPONSE)

For the exact payload structure of each message type, refer to Gadgetbridge:

  https://codeberg.org/Freeyourgadget/Gadgetbridge/src/branch/master/app/
  src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/
  garmin/messages/

Each message type has a corresponding Java class (e.g., FileListRequest.java,
DownloadRequest.java) that documents the byte-level structure. Read the
Java, write Swift equivalents.

### Authentication / OAuth bypass

After connection, the watch's GFDI configuration message will indicate it
supports OAUTH_CREDENTIALS. The official Garmin Connect app provides real
OAuth tokens here. We don't have those.

Gadgetbridge implements a bypass: when the watch sends a protobuf message
asking for OAuth credentials (typically via message 5022 wrapping a specific
protobuf message type GDISetOAuthCredentials), respond with a fake but
structurally valid credentials object. The watch then transitions into
authenticated state and allows file sync.

Implementation: see Gadgetbridge's
`service.devices.garmin.GarminSupport.java` — search for "OAUTH" or
"sendFakeOauth". The protobuf schemas are in the Gadgetbridge repo under
`app/src/main/proto/garmin/`.

⚠️ Critical warning to surface in the UI: Once a watch has been given fake
OAuth credentials, its credentials are invalidated for real Garmin Connect.
Re-authentication with the real Garmin Connect app may require a factory
reset of the watch. The UI must show a clear, dismissable warning before
the user pairs, and only proceed on explicit confirmation.

### File transfer flow

To pull all activity files from the watch:

1. After auth, send FILE_LIST_REQUEST with directory filter for "Activity"
2. Receive FILE_LIST_RESPONSE listing file indices and metadata
3. For each file_index: send DOWNLOAD_REQUEST(file_index)
4. Receive DOWNLOAD_RESPONSE messages with chunks. Each chunk has an offset
   and length. Concatenate into a buffer.
5. When download completes, send ACK
6. Optionally, send ARCHIVE_REQUEST (5007 with archive flag) to mark the
   file as synced — the watch may rotate it from the live directory after
   archiving

Repeat for /Monitor, /Sleep, /Metrics directories with appropriate filter
flags.

To push a course:

1. CREATE_FILE_REQUEST with file type and metadata, receive new file_index
2. Loop: UPLOAD_REQUEST chunks of ~500 bytes each, awaiting
   UPLOAD_RESPONSE ACKs
3. Final UPLOAD_REQUEST with end-of-file flag
4. Verify with file list query

## Swift implementation structure

Build the package as a layered architecture:

```
CompassBLE/Sources/CompassBLE/
├── Public/
│   ├── GarminDeviceManager.swift     # public API surface
│   ├── DiscoveredDevice.swift
│   ├── ConnectedDevice.swift
│   ├── PairingError.swift
│   └── SyncProgress.swift
├── Transport/
│   ├── BluetoothCentral.swift        # CoreBluetooth wrapper, actor-based
│   ├── MLRTransport.swift            # Multi-Link Reliable framing
│   ├── HandleManager.swift           # Multi-Link handle assignment
│   └── FrameAssembler.swift          # Fragment reassembly
├── GFDI/
│   ├── GFDIMessage.swift             # base type, CRC, framing
│   ├── GFDIClient.swift              # high-level send/receive
│   ├── Messages/
│   │   ├── DeviceInformation.swift
│   │   ├── Configuration.swift
│   │   ├── FileList.swift
│   │   ├── Download.swift
│   │   ├── Upload.swift
│   │   ├── CreateFile.swift
│   │   └── Protobuf.swift
│   └── MessageTypes.swift            # enum of known type codes
├── Auth/
│   ├── AuthenticationManager.swift   # OAuth bypass orchestration
│   ├── ProtobufBridge.swift          # SwiftProtobuf encode/decode
│   └── FakeOAuthCredentials.swift
├── Sync/
│   ├── FileSyncCoordinator.swift     # orchestrates list+download
│   ├── FileUploader.swift            # chunked upload with ACKs
│   └── FileMetadata.swift
└── Utils/
    ├── CRC16.swift                   # Garmin uses standard CRC-16-CCITT
    ├── ByteReader.swift              # little-endian reading helpers
    └── Logger.swift                  # subsystem-tagged os.Logger wrapper
```

### Concurrency model

- `BluetoothCentral` is an actor wrapping CBCentralManager. All Core
  Bluetooth callbacks are forwarded into the actor's task context.
- `MLRTransport` is an actor maintaining per-handle inbound/outbound state.
- `GFDIClient` is an actor with a request/response correlator: sends a
  message and awaits the matching response by GFDI message type.
- The public `GarminDeviceManager` exposes `async throws` methods and an
  `AsyncStream<SyncProgress>` for UI updates.

Use Swift 6 strict concurrency — every shared state is in an actor,
sendable types throughout.

### Public API

```swift
public actor GarminDeviceManager {
    public init()

    public nonisolated func discover() -> AsyncStream<DiscoveredDevice>
    public func stopDiscovery()

    public func pair(_ device: DiscoveredDevice) async throws
        -> ConnectedDevice
    public func connect(_ device: ConnectedDevice) async throws
    public func disconnect()

    public func pullFITFiles(
        directories: Set<FITDirectory>,
        progress: AsyncStream<SyncProgress>.Continuation?
    ) async throws -> [URL]

    public func uploadCourse(_ url: URL) async throws

    public var isConnected: Bool { get }
    public var connectedDevice: ConnectedDevice? { get }
}

public enum FITDirectory {
    case activity, monitor, sleep, metrics
}
```

The pull function writes fetched FIT files to a temp directory and returns
their local URLs. The caller (SyncCoordinator in the main app) feeds them to
CompassFIT for parsing.

### Pairing flow

1. User taps "Pair a device" in Settings
2. Use AccessorySetupKit (`ASAccessorySession`) to present an Apple-style
   pairing sheet filtered to the Garmin BLE service UUID
3. User selects their watch and taps Approve in the sheet
4. The system pairs at the BLE level
5. Show the OAuth-bypass warning to the user, await explicit confirmation
6. Connect, do the configuration handshake, send fake OAuth credentials
7. On success, persist a `ConnectedDevice` to SwiftData via the data layer
8. On failure (timeout, watch refuses, etc.), show clear error and clean up

### Things to mock vs. implement fully

For the MVP target — and given that you (Claude Code) cannot test against a
real watch — implement the full protocol logic to the best of your ability,
but assume verification happens later by the user with hardware.

Required deliverables in this pass:
- Full MLR framing implementation with unit tests using captured byte
  sequences from Gadgetbridge issue logs (cite the issue numbers for
  traceability)
- Full GFDI message structure with unit tests for encoding/decoding each
  message type, using fixture bytes
- AuthenticationManager with the OAuth-bypass flow stubbed in detail —
  the actual protobuf message bytes can be left as TODOs with clear
  comments referencing where to find them in the Gadgetbridge repo, but
  the orchestration logic should be complete
- CRC16-CCITT implementation tested against known vectors
- A `MockGarminDevice` that fakes the entire flow, used for UI/integration
  tests and DEBUG builds. It should:
  - Return synthetic FIT files for the various directories
  - Simulate realistic timing (5-30 sec per file pull)
  - Simulate progress events
  - Optionally simulate failure modes (timeout, disconnect mid-transfer)
- Integration test: end-to-end pair → auth → pull → parse against
  MockGarminDevice, verifying that resulting FIT files round-trip through
  CompassFIT correctly

### Protobuf handling

For GFDI messages 5022/5023, payloads are protobuf-encoded. Use
SwiftProtobuf (add via SwiftPM: `https://github.com/apple/swift-protobuf`).

Generate Swift bindings from Gadgetbridge's .proto files:
- `app/src/main/proto/garmin/` in the Gadgetbridge repo

You'll need at minimum:
- Smart.proto (umbrella)
- Auth.proto (or wherever GDISetOAuthCredentials lives)
- DeviceStatus.proto

Add a build-time step (or commit pre-generated .pb.swift files) that runs
`protoc` against these schemas. Document the regeneration process in
docs/PROTOBUF.md.

### Logging

Use os.Logger with subsystem `com.compass.ble` and categories per layer
(`transport`, `gfdi`, `auth`, `sync`). At debug level, log every BLE
notification's first 32 bytes in hex. Make it easy to enable verbose logging
via a debug toggle in the app.

### Failure modes to handle

- Watch in airplane mode / out of range → discoverable timeout, surface
  cleanly
- Watch refuses pairing (already paired to Garmin Connect on a phone) →
  detect via early disconnect, surface a "unpair from other apps first"
  error
- Authentication denied (perhaps Garmin patched the bypass) → fall back to
  read-only mode that can still list and possibly pull older files
- Mid-transfer disconnect → resume from last-acked offset on next sync
- Watch firmware updates that change the protocol → log unknown message
  types verbosely so the user can file an issue with logs

### Testing strategy

Two test targets in the package:

1. `CompassBLETests` — unit tests:
   - MLR framing round-trip
   - GFDI message encode/decode
   - CRC16
   - Fragment reassembly across BLE MTU boundaries

2. `CompassBLEIntegrationTests` — uses `MockGarminDevice`:
   - Full pair → auth → pull flow
   - Upload flow
   - Failure injection

Add CI hints in README.md showing how to run each.

## Constraints and reminders

- iOS 18+ only. AccessorySetupKit is iOS 18.
- Swift 6 strict concurrency.
- No third-party dependencies except SwiftProtobuf.
- All user-facing strings must avoid Garmin trademarks. Internal code,
  comments, log messages, and types can name Garmin freely.
- The OAuth bypass warning copy must be clear about the consequences.
- Each public function needs a docc comment explaining behavior, errors,
  and side effects.

## What to deliver

1. Complete CompassBLE package source matching the layout above
2. Unit tests with fixture byte sequences (cite Gadgetbridge issue numbers
   when borrowing capture data)
3. MockGarminDevice with realistic synthetic data
4. SwiftProtobuf integration with placeholder .pb.swift files for the key
   messages, plus a docs/PROTOBUF.md regen guide
5. Updated README.md section on the BLE module: how it works, how to debug,
   how to test against a real watch, known limitations
6. Updated ARCHITECTURE.md describing the actor model and data flow
7. A docs/PROTOCOL_REFERENCE.md that summarizes the MLR + GFDI specifications
   with citations to Gadgetbridge wiki pages and source files — so the next
   developer (or future-you) can debug protocol issues without re-reading
   the entire Gadgetbridge codebase
8. A docs/TESTING.md describing how to capture BLE traffic from a real
   device using PacketLogger on macOS for debugging

The end state of this pass: the CompassBLE package compiles, all unit and
integration tests pass against MockGarminDevice, and the integration with
the rest of the Compass app means tapping "Sync" in the UI runs the full
mock flow successfully and displays the parsed mock data.

When you encounter a Gadgetbridge protocol detail you can't find from the
context provided, search for it. Cite the URL and commit hash when you do.

If a particular message's byte structure isn't documented anywhere you
can find, mark it as `// TODO: verify against real device capture` and
implement based on best understanding. Never silently guess at byte
layouts — every speculation must be flagged.

Begin with the transport layer (BluetoothCentral and MLRTransport) since
everything depends on it. Then GFDI framing, then specific message types,
then auth, then sync orchestration. Run the relevant tests after each
layer is complete to verify before moving up.

# Plan: GPX Course Upload to Garmin Watch

## Context

Users want to load GPX routes onto their Garmin watch as navigable courses. This means:
1. Parsing a GPX file into a `Course` data model
2. Encoding it as a binary FIT course file (the format the watch expects)
3. Uploading the FIT bytes to the watch via BLE using the Garmin GFDI file-upload protocol
4. A new "Courses" tab in the app to manage this

The upload direction (phone → watch) mirrors the already-implemented download path (`FileSyncSession`) but uses three new GFDI messages not yet implemented: `CreateFileMessage` (5005), `UploadRequestMessage` (5003), and a `FileTransferData` encoder (the decoder already exists).

Research performed via GadgetBridge source code audit + Garmin FIT SDK docs. All protocol details documented in `docs/garmin/gadgetbridge-sync.md §8`.

---

## Deliverables

1. **Spec doc** — `docs/garmin/course-upload.md` — protocol walkthrough + FIT encoding reference
2. **Data layer** — `Course` + `CourseWaypoint` SwiftData models in CompassData
3. **GPX parser** — `GPXCourseParser` in CompassFIT (Apple XMLParser, no extra dependency)
4. **FIT encoder** — `CourseFITEncoder` in CompassFIT
5. **Upload messages** — 5 new GFDI message structs in CompassBLE
6. **Upload session** — `FileUploadSession` actor (mirrors `FileSyncSession`)
7. **Wire-up** — `GarminDeviceManager.uploadCourse` + `SyncCoordinator.uploadCourse`
8. **UX** — `CoursesListView`, `CourseDetailView`, new Courses tab

---

## Phase 1: Spec Doc

Create `docs/garmin/course-upload.md` covering:
- The 5-step BLE upload protocol (CreateFile → UploadRequest → chunk loop → SYNC_COMPLETE)
- Exact byte layouts for all 5 messages
- FIT course file structure (file_id, course, lap, record×N, course_point×N)
- Field encodings (semicircles, altitude scale, Garmin epoch)
- Known quirks (RESPONSE wrapping, random nonce, DUPLICATE handling)

---

## Phase 2: Data Layer

**New files in `Packages/CompassData/Sources/CompassData/Models/`:**

### `Course.swift`
```swift
@Model final class Course {
    var id: UUID
    var name: String
    var importDate: Date
    var sport: Sport          // default .running
    var totalDistance: Double  // meters
    var totalAscent: Double?   // meters
    var waypoints: [CourseWaypoint]
    // Transient: URL of the original .fit bytes in Documents/
    var fitFileURL: URL?
}
```

### `CourseWaypoint.swift`
```swift
@Model final class CourseWaypoint {
    var order: Int
    var latitude: Double
    var longitude: Double
    var altitude: Double?     // meters
    var name: String?         // for turn-by-turn prompts
    var distanceFromStart: Double  // meters (cumulative Haversine)
    var course: Course?
}
```

**Modified files:**
- `CompassApp.swift` — add `Course.self, CourseWaypoint.self` to the `Schema([...])` array
- `ContentView.swift` preview — add them to `modelContainer(for:)`
- `MockDataProvider.swift` — seed 2–3 sample courses (simple loops near SF using existing TrackPoint lat/lon range)

---

## Phase 3: GPX Parser

**New file: `Packages/CompassFIT/Sources/CompassFIT/Parsers/GPXCourseParser.swift`**

Uses `XMLParser` (Foundation, no extra dependency). Parses:
- `<trk><trkpt lat="..." lon="..."><ele>...</ele></trkpt></trk>` → ordered `CourseWaypoint`s with cumulative distance
- `<wpt lat="..." lon="..."><name>...</name></wpt>` → named waypoints merged into the closest trackpoint (snap by min-distance)
- `<name>` at `<trk>` level → course name; falls back to filename stem

Returns `Course` (not yet inserted into SwiftData context — caller inserts).

Haversine helper (static, in this file) computes great-circle distance between consecutive points to accumulate `distanceFromStart`.

---

## Phase 4: FIT Course Encoder

**New file: `Packages/CompassFIT/Sources/CompassFIT/Encoders/CourseFITEncoder.swift`**

Produces a binary FIT file accepted by the Garmin Instinct Solar (`dataType=128 / subType=6`).

### FIT message sequence
```
FIT file header (14 bytes)
Definition message (local type 0) → file_id (global 0)
Data message: file_id { type=6, manufacturer=255, product=1, time_created=<garmin epoch> }

Definition message (local type 1) → course (global 31)
Data message: course { name=<padded 16 bytes>, sport=<0/1/2> }

Definition message (local type 2) → lap (global 19)
Data message: lap { start/end semicircles, total_elapsed_time (ms), total_distance (cm) }

Definition message (local type 3) → record (global 20)
For each waypoint:
  Data message: record { timestamp, lat (semicircles), lon (semicircles), alt (scaled), distance (cm) }

[If course has named waypoints:]
Definition message (local type 4) → course_point (global 32)
For each named waypoint:
  Data message: course_point { timestamp, lat, lon, distance (cm), type=0 generic, name[16] }

FIT file CRC (2 bytes) — CRC16.compute(data: entireDataSection, seed: 0)
```

### Key encodings (reuse existing helpers)
- `degreesToSemicircles(deg: Double) -> Int32`: `Int32(deg * (pow(2.0, 31) / 180.0))`
- Altitude: `UInt16((alt + 500) * 5)`
- Distance: `UInt32(meters * 100)`
- Elapsed time: `UInt32(seconds * 1000)`
- Timestamps: all sequential (1s apart from `Date()` at import time, or real GPX times)
- Uses `Data.appendUInt8/appendInt32LE/appendUInt16LE/appendUInt32LE` from `DeviceInformation.swift`
- Trailing file CRC: `CRC16.compute(data: bodyBytes, seed: 0)` (same Garmin nibble-table)

---

## Phase 5: Upload GFDI Messages

**New file: `Packages/CompassBLE/Sources/CompassBLE/Messages/CourseUpload.swift`**

Five structs, following the exact encoding pattern of existing messages:

### `CreateFileMessage` (type 5005 = `.createFile`)
Encode (`toMessage() -> GFDIMessage`):
```
[UInt32 LE] fileSize
[UInt8]     fileDataType = 128
[UInt8]     fileSubType  = 6  (course)
[UInt16 LE] fileIndex    = 0  (let watch assign)
[UInt8]     reserved     = 0
[UInt8]     subtypeMask  = 0
[UInt16 LE] numberMask   = 0xFFFF
[UInt16 LE] unknown      = 0
[8 bytes]   nonce        = random (use SecRandomCopyBytes)
```
Total payload: 22 bytes.

### `CreateFileStatus` (decode from RESPONSE wrapping 5005)
```
[UInt8]     status        (0 = OK)
[UInt8]     createStatus  (0=OK, 1=DUPLICATE, 2=NO_SPACE, 3=UNSUPPORTED, 4=NO_SLOTS)
[UInt16 LE] fileIndex     (assigned by watch)
[UInt8]     fileDataType
[UInt8]     fileSubType
[UInt16 LE] fileNumber
```

### `UploadRequestMessage` (type 5003 = `.uploadRequest`)
Encode:
```
[UInt16 LE] fileIndex  (from CreateFileStatus)
[UInt32 LE] dataSize   (total bytes)
[UInt32 LE] dataOffset = 0
[UInt16 LE] crcSeed    = 0
```
Total payload: 12 bytes.

### `UploadRequestStatus` (decode from RESPONSE wrapping 5003)
```
[UInt8]     status        (0 = OK)
[UInt8]     uploadStatus  (0=OK, 1=INDEX_UNKNOWN, 3=NO_SPACE)
[UInt32 LE] dataOffset    (must equal 0)
[UInt32 LE] maxPacketSize (max bytes per chunk)
[UInt16 LE] crcSeed
```

### `FileTransferDataChunk` (encode only — decode already exists)
```
[UInt8]     flags       (0x00 = middle, 0x08 = last)
[UInt32 LE] dataOffset
[UInt16 LE] chunkCRC    (running CRC over bytes sent so far)
[N bytes]   data
```
`maxChunkData = maxPacketSize - 13` bytes per chunk.

**Note:** The Instinct Solar returns `CreateFileStatus` and `UploadRequestStatus` as full `RESPONSE (0x1388)` frames, not compact-typed — same pattern as `DownloadRequestStatus`. Decode using `GFDIResponse` + inner `ByteReader`, identical to how `DownloadRequestStatus.decode(from:)` works.

---

## Phase 6: FileUploadSession

**New file: `Packages/CompassBLE/Sources/CompassBLE/Sync/FileUploadSession.swift`**

```swift
actor FileUploadSession {
    init(client: GFDIClient, maxPacketSize: Int = 375)

    func upload(
        data: Data,
        fileType: FileType,
        progress: AsyncStream<SyncProgress>.Continuation?
    ) async throws
}
```

### Upload flow (mirrors FileSyncSession download)

```
1. Send CreateFileMessage(fileSize: data.count, fileType: .course)
   Wait for RESPONSE (awaitType: .response, timeout: 10s)
   Decode CreateFileStatus — throw on createStatus != 0

2. Send UploadRequestMessage(fileIndex: assignedIndex, dataSize: data.count)
   Wait for RESPONSE (awaitType: .response, timeout: 10s)
   Decode UploadRequestStatus — extract effectiveChunkSize = min(maxPacketSize, self.maxPacketSize) - 13

3. Subscribe to .response (for per-chunk ACKs) BEFORE sending first chunk

4. Chunk loop:
   offset = 0, runningCRC = 0
   while offset < data.count:
     chunkData = data[offset ..< min(offset+chunkSize, data.count)]
     isLast = (offset + chunkData.count >= data.count)
     runningCRC = CRC16.compute(data: chunkData, seed: runningCRC)
     send FileTransferDataChunk(flags: isLast ? 0x08 : 0x00,
                                 dataOffset: offset,
                                 chunkCRC: runningCRC,
                                 data: chunkData)
     await next ACK from subscription
     decode nextDataOffset from ACK — use as next offset
     progress?.yield(...)

5. Unsubscribe (synchronously, same pattern as FileSyncSession)
6. Send SystemEvent(syncComplete)
```

On error: send abort chunk (flags = 0x0C, size 0), unsubscribe, rethrow.

---

## Phase 7: Wire-Up

### `GarminDeviceManager.uploadCourse(_ url: URL) async throws`
Replace stub with:
```swift
let data = try Data(contentsOf: url)
let session = FileUploadSession(client: gfdiClient, maxPacketSize: pktSize)
try await session.upload(data: data, fileType: .course, progress: nil)
```

### `SyncCoordinator`
Add method `uploadCourse(fitURL: URL) async throws`:
- Sets `state = .syncing("Uploading course…")`
- Calls `deviceManager.uploadCourse(fitURL)`
- Sets `state = .completed(fileCount: 1)` on success / `.failed(error.localizedDescription)` on error
- Resets to `.idle` after 3 s

Add `var uploadProgress: Double = 0` to expose chunk progress to the UI.

---

## Phase 8: UX

### `CoursesListView.swift` (new)
- `NavigationStack` wrapping `List(.plain)`
- `@Query(sort: \Course.importDate, order: .reverse) var courses: [Course]`
- Toolbar: `+` button → `fileImporter(isPresented:, allowedContentTypes: [.xml, .gpx])` sheet
  - On file pick: `SecurityScopedResource`, `GPXCourseParser.parse(data:)`, insert into context
  - Show inline error alert on parse failure
- Each row: `NavigationLink → CourseDetailView`
  - `MapSnapshotView` thumbnail (adapt to accept `[CourseWaypoint]` coordinates)
  - Course name, import date, distance string

### `CourseDetailView.swift` (new)
- Full-width `MapRouteView` hero (adapt to accept `[CourseWaypoint]`)
- Stats grid (`StatCell`): distance, ascent, waypoint count, sport
- "Upload to Watch" button
  - Disabled when not connected (`syncCoordinator.connectionState != .connected`)
  - On tap: encode `course` → FIT bytes (via `CourseFITEncoder`) → write to temp file → call `syncCoordinator.uploadCourse(fitURL:)`
  - Shows spinner / "Uploaded" / error inline using `syncCoordinator.state`

### `ContentView.swift` modification
Add after Health tab:
```swift
Tab("Courses", systemImage: "map") {
    CoursesListView()
}
```

### Map view adaptation
Both `MapRouteView` and `MapSnapshotView` accept `[TrackPoint]`. Add a small overload/extension accepting `[CLLocationCoordinate2D]` or add a `CourseWaypoint → CLLocationCoordinate2D` computed property, keeping existing `TrackPoint` paths unchanged.

---

## Critical Files

| File | Action |
|---|---|
| `docs/garmin/course-upload.md` | Create (new spec doc) |
| `Packages/CompassData/.../Models/Course.swift` | Create |
| `Packages/CompassData/.../Models/CourseWaypoint.swift` | Create |
| `Packages/CompassFIT/.../Parsers/GPXCourseParser.swift` | Create |
| `Packages/CompassFIT/.../Encoders/CourseFITEncoder.swift` | Create |
| `Packages/CompassBLE/.../Messages/CourseUpload.swift` | Create |
| `Packages/CompassBLE/.../Sync/FileUploadSession.swift` | Create |
| `Packages/CompassBLE/.../Public/GarminDeviceManager.swift:559` | Implement stub |
| `Compass/App/SyncCoordinator.swift` | Add `uploadCourse` method |
| `Compass/App/CompassApp.swift` | Add Course + CourseWaypoint to Schema |
| `Compass/Views/ContentView.swift` | Add Courses tab |
| `Compass/Views/Activity/MapRouteView.swift` | Add coordinate overload |
| `Compass/Views/Activity/MapSnapshotView.swift` | Add coordinate overload |
| `Compass/Views/Courses/CoursesListView.swift` | Create |
| `Compass/Views/Courses/CourseDetailView.swift` | Create |
| `Packages/CompassData/.../MockDataProvider.swift` | Seed mock courses |

---

## Reuse Checklist

- `FileType.course = 6` — already correct for CreateFileMessage.fileSubType ✓
- `FileEntry.garminEpochFromDate(_:)` — for FIT timestamps ✓
- `CRC16.compute(data:seed:)` — for both chunk CRC and FIT file trailing CRC ✓
- `Data.appendUInt8/Int8/UInt16LE/Int32LE/UInt32LE` — for all FIT + message encoding ✓
- `GFDIClient.sendAndWait/subscribe/unsubscribe` — for upload session transport ✓
- `SystemEventMessage(.syncComplete)` — closes the upload session ✓
- `GFDIResponse` + `ByteReader` — for decoding CreateFileStatus + UploadRequestStatus ✓
- `MapRouteView` / `MapSnapshotView` — course map preview (needs coordinate overload) ✓
- `StatCell` / `chartCard` — course detail stats ✓
- `ActivityRowView` structure — course row layout ✓

---

## Known Risks & Mitigations

| Risk | Mitigation |
|---|---|
| `CreateFileStatus.createStatus == DUPLICATE` | Alert user: "A course with this name already exists on the watch." Offer rename. |
| `createStatus == NO_SPACE` | Alert: "Not enough space on watch for this course." |
| Watch returns full `RESPONSE(0x1388)` for CreateFileStatus (same quirk as DownloadRequestStatus) | Decode via `GFDIResponse.decode` then inner payload — matches existing download pattern |
| 8-byte nonce must be non-zero | Use `var nonce = Data(count: 8); _ = SecRandomCopyBytes(kSecRandomDefault, 8, &nonce)` |
| FIT trailing CRC must be over data section only (not header) | Track `headerBytes` separately; CRC input = `definitionMessages + dataMessages` |
| Large courses (1000+ waypoints ≈ 100 KB) take ~300 chunks | Progress bar in UI; no timeout issue since per-chunk ACK drives the loop |

---

## Verification

1. Build compiles with no warnings
2. Preview of `CoursesListView` renders mock courses (MapSnapshotView thumbnails visible)
3. `GPXCourseParser` unit test: parse a minimal GPX with 3 track points + 1 named waypoint; assert correct `distanceFromStart`, `name`, coordinate values
4. `CourseFITEncoder` unit test: encode a 3-point course; verify FIT header magic (`0x0E 0x10`), file_id type byte = 6, record count = 3, trailing CRC valid (re-compute with `CRC16.compute`)
5. Integration test (existing `MockDeviceIntegrationTests.uploadCourse`): currently throws "not implemented"; after Phase 7 it should complete without error against `MockGarminDevice`
6. Manual test against real Instinct Solar: watch shows the course in Training → Courses within 30 s of upload

# Plan: PhoneLocation service

Push the phone's GPS coordinates to the watch via the GFDI protobuf channel.

**Effect on watch:** the watch uses the received coordinates to compute its
sunrise/sunset widget, display a "phone location" breadcrumb, and keep its
time zone current. Without this push the watch falls back to whatever home
location was last set in its own settings.

---

## Background

### Protocol (verified against Gadgetbridge `GarminSupport.onSetGpsLocation`)

The phone sends an unsolicited `Smart` protobuf message on the GFDI link
(message type **0x13B4** — `PROTOBUF_RESPONSE`) containing:

```
Smart (outer wrapper)
└─ coreService [field 13]: CoreService
   └─ locationUpdatedNotification [field 7]: LocationUpdatedNotification
      └─ locationData [field 1, repeated]: LocationData
         ├─ position     [1]: LatLon   { lat [1]: sint32, lon [2]: sint32 }
         ├─ altitude     [2]: float
         ├─ timestamp    [3]: uint32   (Garmin epoch)
         ├─ h_accuracy   [4]: float    (metres)
         ├─ v_accuracy   [5]: float    (metres)
         ├─ position_type[6]: enum     2 = REALTIME_TRACKING
         ├─ bearing      [9]: float    (degrees, 0–360)
         └─ speed        [10]: float   (m/s)
```

**Coordinate encoding:** lat/lon in semicircles — `degrees × (2³¹ / 180)` —
exactly the same scale as FIT sint32 lat/lon fields.

**Trigger:** Gadgetbridge sends this every time the Android `GBLocationService`
reports a significant location change. For Compass, send on connect + on each
`CLLocation` update while the watch is connected.

### Current state of outbound protobuf

- `GarminMessageType.protobufResponse` (0x13B4) is defined in `MessageTypes.swift`
  but never sent.
- No SwiftProtobuf dependency exists in the project.
- Incoming `PROTOBUF_REQUEST` (0x13B3) messages are ACK'd only; their payload
  is not decoded.

---

## Implementation plan

### Step 1 — Decide: SwiftProtobuf vs hand-rolled encoding

**Option A — Hand-rolled (recommended for now)**

The `Smart → CoreService → LocationUpdatedNotification → LocationData` message
contains only `sint32`, `float`, `uint32`, and `enum` field types. Writing a
minimal protobuf varint/wire-type encoder (~80 lines) avoids adding an external
dependency and keeps the package self-contained.

A `ProtoEncoder` helper is sufficient:
```swift
var enc = ProtoEncoder()
enc.writeSInt32(field: 1, value: latSemicircles)  // zigzag encoded
enc.writeSInt32(field: 2, value: lonSemicircles)
// ...
```

**Option B — SwiftProtobuf**

If the project later needs to send/receive other protobuf messages (notifications,
calendar, settings) the investment in `swift-protobuf` + code generation pays
off. See `docs/PROTOBUF.md` for the full setup guide.

**Decision point:** start with Option A. Revisit when a second protobuf-backed
feature is added.

---

### Step 2 — `ProtoEncoder` utility (Option A path)

**File:** `Packages/CompassBLE/Sources/CompassBLE/Utils/ProtoEncoder.swift`

Implement the minimal subset needed:

| Wire type | Used for      | Encoding        |
|-----------|---------------|-----------------|
| 0 (varint)| uint32, enum  | LEB128          |
| 0 (varint)| sint32        | zigzag + LEB128 |
| 2 (len)   | embedded msg  | length-prefixed |
| 5 (32-bit)| float         | little-endian   |

Public API:
```swift
struct ProtoEncoder {
    private(set) var data = Data()
    mutating func writeUInt32(field: Int, value: UInt32)
    mutating func writeSInt32(field: Int, value: Int32)   // zigzag
    mutating func writeFloat(field: Int, value: Float)
    mutating func writeEnum(field: Int, value: Int)
    mutating func writeMessage(field: Int, body: Data)
    mutating func writeBytes(field: Int, value: Data)
}
```

---

### Step 3 — `PhoneLocationEncoder`

**File:** `Packages/CompassBLE/Sources/CompassBLE/GFDI/Messages/PhoneLocation.swift`

Encode a single `CLLocation` into a ready-to-send `GFDIMessage`:

```swift
public enum PhoneLocationEncoder {
    public static func encode(
        latDegrees: Double,
        lonDegrees: Double,
        altitude: Float,        // metres (use 0 if unavailable)
        hAccuracy: Float,       // metres
        vAccuracy: Float,       // metres (use hAccuracy if unavailable)
        bearing: Float,         // degrees 0–360 (use 0 if unavailable)
        speed: Float,           // m/s (use 0 if unavailable)
        garminTimestamp: UInt32
    ) -> GFDIMessage
}
```

Internal encoding:

```
latSemicircles  = Int32(latDegrees  * 2^31 / 180)
lonSemicircles  = Int32(lonDegrees  * 2^31 / 180)

latLon  = ProtoEncoder { writeSInt32(1, lat); writeSInt32(2, lon) }
locData = ProtoEncoder {
    writeMessage(1, latLon.data)
    writeFloat(2, altitude)
    writeUInt32(3, garminTimestamp)
    writeFloat(4, hAccuracy)
    writeFloat(5, vAccuracy)
    writeEnum(6, 2)              // REALTIME_TRACKING
    writeFloat(9, bearing)
    writeFloat(10, speed)
}
locNotif = ProtoEncoder { writeMessage(1, locData.data) }
core     = ProtoEncoder { writeMessage(7, locNotif.data) }
smart    = ProtoEncoder { writeMessage(13, core.data) }

→ GFDIMessage(type: .protobufResponse, payload: smart.data)
```

---

### Step 4 — `PhoneLocationService`

**File:** `Compass/Services/PhoneLocationService.swift`

```swift
@MainActor
final class PhoneLocationService: NSObject, CLLocationManagerDelegate {

    private let locationManager = CLLocationManager()
    var sendMessage: ((GFDIMessage) async -> Void)?

    func startUpdating() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 500          // metres between updates
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }

    func stopUpdating() { locationManager.stopUpdatingLocation() }

    func nonisolated func locationManager(_ manager: CLLocationManager,
                                          didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in await push(loc) }
    }

    private func push(_ loc: CLLocation) async {
        let ts = garminTimestamp(from: loc.timestamp)
        let msg = PhoneLocationEncoder.encode(
            latDegrees: loc.coordinate.latitude,
            lonDegrees: loc.coordinate.longitude,
            altitude: Float(loc.altitude),
            hAccuracy: Float(loc.horizontalAccuracy),
            vAccuracy: Float(loc.verticalAccuracy > 0 ? loc.verticalAccuracy
                                                      : loc.horizontalAccuracy),
            bearing: Float(loc.course > 0 ? loc.course : 0),
            speed: Float(max(0, loc.speed)),
            garminTimestamp: ts
        )
        await sendMessage?(msg)
    }

    private static let garminEpochOffset: TimeInterval = 631_065_600
    private func garminTimestamp(from date: Date) -> UInt32 {
        UInt32(max(0, date.timeIntervalSince1970 - Self.garminEpochOffset))
    }
}
```

---

### Step 5 — Wire into `SyncCoordinator`

In `wireUpDeviceCallbacks()`:

```swift
phoneLocationService.sendMessage = { [weak gm] msg in
    try? await gm?.sendRaw(message: msg)
}
phoneLocationService.startUpdating()
```

In `tearDownDeviceCallbacks()`:

```swift
phoneLocationService.stopUpdating()
phoneLocationService.sendMessage = nil
```

Also send an immediate push on connect (don't wait for the next location
delegate callback):

```swift
if let last = locationManager.location {
    await push(last)
}
```

---

### Step 6 — `GarminDeviceManager.sendRaw`

Add a small escape-hatch method so services can send arbitrary `GFDIMessage`
values without needing a dedicated setter per feature:

```swift
public func sendRaw(message: GFDIMessage) async throws {
    try await gfdiClient.send(message: message)
}
```

Add `sendRaw(message:)` to `DeviceManagerProtocol` as well.

---

### Step 7 — `Info.plist` / `project.yml`

```yaml
INFOPLIST_KEY_NSLocationWhenInUseUsageDescription:
  "Compass sends your location to the watch for sunrise/sunset and timezone."
```

---

## Files to create / modify

| File | Action |
|------|--------|
| `Packages/CompassBLE/Sources/CompassBLE/Utils/ProtoEncoder.swift` | **New** — minimal protobuf encoder |
| `Packages/CompassBLE/Sources/CompassBLE/GFDI/Messages/PhoneLocation.swift` | **New** — message encoder |
| `Compass/Services/PhoneLocationService.swift` | **New** — CoreLocation → GFDI bridge |
| `Packages/CompassBLE/Sources/CompassBLE/Public/GarminDeviceManager.swift` | Add `sendRaw(message:)` |
| `Packages/CompassBLE/Sources/CompassBLE/Public/DeviceManagerProtocol.swift` | Add `sendRaw(message:)` |
| `Compass/App/SyncCoordinator.swift` | Wire service in/out on connect/disconnect |
| `project.yml` | Add `NSLocationWhenInUseUsageDescription` |

---

## Open questions

1. **Frequency:** Gadgetbridge sends on every "significant" location change.
   A `distanceFilter` of 500 m is a reasonable starting point; adjust if the
   watch updates sunset/sunrise too slowly in practice.

2. **Background location:** `requestWhenInUseAuthorization` means updates stop
   when the app is backgrounded. Garmin Connect likely uses
   `requestAlwaysAuthorization`. Decide based on privacy trade-off.

3. **Does the watch actually update sunset/sunrise from this?** Needs testing.
   An alternative path is the watch's `DEVICE_SETTINGS` message (a different
   GFDI type) that carries timezone/location for the watch clock. If location
   push alone doesn't update the widget, investigate that path too.

4. **protobuf ACK:** After sending, the watch may reply with a
   `PROTOBUF_REQUEST` (0x13B3) ACK. The existing handler in `GarminDeviceManager`
   already ACKs those — no additional work needed.

---

## Reference

- Gadgetbridge `GarminSupport.onSetGpsLocation` — call chain and field values
- Gadgetbridge `GarminUtils.toLocationData` — coordinate scaling
- Gadgetbridge `gdi_core.proto` — `LocationData`, `LocationUpdatedNotification`, `DataType`
- Gadgetbridge `GdiSmartProto.proto` — `Smart` wrapper (CoreService = field 13)

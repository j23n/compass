# WP-1 · BLE Connection Lifecycle — Implementation Plan

## Implementation Order

Dependencies drive this sequence:

1. **Task 4 — Swipe-to-delete confirmation** (trivial, no deps)
2. **Task 3 — Sync cancel propagation** (stand-alone, high user-visible pain)
3. **Task 2 — Reconnect/bond persistence** (`mFirstConnect` flag)
4. **Task 5 — Settings: manual disconnect/reconnect** (builds on Task 2)
5. **Task 1 — Background BLE entitlement** (prerequisite for Tasks 6 & 7)
6. **Task 6 — BLE heartbeat** (requires background mode to be meaningful)
7. **Task 7 — Seamless reconnect + persistent background** (highest complexity)

---

## Task 1 — Background BLE Entitlement & State Restoration

**Risk: MEDIUM**

`bluetooth-central` background mode is already in `project.yml`. The missing piece is `CBCentralManagerOptionRestoreIdentifierKey`, without which iOS cannot re-attach the process to an existing BLE session after termination.

### `BluetoothCentral.swift` — `ensureCentralManager()`

Pass the restore key when creating the `CBCentralManager`:

```swift
let options: [String: Any] = [
    CBCentralManagerOptionRestoreIdentifierKey: "com.compass.app.central"
]
self.centralManager = CBCentralManager(delegate: adapter, queue: nil, options: options)
```

Add `centralManager(_:willRestoreState:)` to `CentralManagerDelegateAdapter`. Bridge it to a new `func didRestoreState(_ dict: [String: Any])` on `BluetoothCentral`. Inside:
- Recover `connectedPeripheral` from `CBCentralManagerRestoredStatePeripheralsKey`
- Re-assign the delegate adapter
- Re-acquire write/notify characteristics from `CBCentralManagerRestoredStateServicesKey`
- Fire `disconnectHandler` so `GarminDeviceManager` can evaluate whether re-pairing is needed

**Investigation needed:** When iOS restores the `CBCentralManager`, the peripheral may already be in `CBPeripheralState.connected`. The current `connect()` always sends `CLOSE_ALL + REGISTER_ML`. If the watch's ML handle pool still has the GFDI handle open, sending `CLOSE_ALL` should reset it cleanly — but this must be tested on device. If `CLOSE_ALL` causes a disconnect, the restore path needs to detect the already-open handle and skip the ML init.

**Acceptance criteria:**
- App relaunched from background re-establishes the GFDI session without re-doing the full handshake
- Simulator: this has no effect (state restoration doesn't work in Simulator) — test on device only

---

## Task 2 — Reconnect/Bond Persistence (`mFirstConnect`)

**Risk: LOW**

Every `connect()` currently sends `PAIR_COMPLETE / SYNC_COMPLETE / SETUP_WIZARD_COMPLETE`, which confuses the watch's state machine on reconnect. Only the first connect per watch should send these.

### `GarminDeviceManager.swift`

Add a private stored property:

```swift
private var hasConnectedOnce: Bool = false
```

Split `runHandshake()` into two phases:
- `runHandshakePreamble()` — handles `DEVICE_INFORMATION` ACK, `CONFIGURATION` exchange, `SUPPORTED_FILE_TYPES_REQUEST`, `DEVICE_SETTINGS`. **Always runs.**
- Existing `runHandshake()` calls `runHandshakePreamble()`, then sends `SYNC_READY / PAIR_COMPLETE / SYNC_COMPLETE / SETUP_WIZARD_COMPLETE` **only if `!hasConnectedOnce`**. Sets `hasConnectedOnce = true` after first successful completion.

On reconnect: after `runHandshakePreamble()` succeeds, send only `SYNC_READY`. Skip pairing events.

`pair()` must set `hasConnectedOnce = false` before calling `runHandshake()`, so a deliberate re-pair always runs the full sequence.

**Acceptance criteria:**
- After first pair, watch exits setup wizard
- On reconnect, logs must NOT contain "Sending PAIR_COMPLETE / SETUP_WIZARD_COMPLETE"
- Watch home screen appears immediately on reconnect

---

## Task 3 — Sync Cancel Propagation

**Risk: LOW-MEDIUM**

The root issue: `for await chunkMsg in chunkStream` in `FileSyncSession.downloadData()` does not respond to Swift task cancellation — `AsyncStream` iteration is not a cooperative cancellation point.

**Investigation before committing:** Verify empirically that cancelling the outer `Task` from `SyncCoordinator.cancelSync()` does NOT cause `FileSyncSession.downloadData()` to exit. If it does exit (via a thrown `CancellationError`), the fix below is still correct but less urgent.

On watch-side abort behavior: Gadgetbridge does not send an explicit abort message — it drops the link. Send an abort ACK conservatively; do NOT send `SYNC_COMPLETE` on user cancel (it would mark the sync as successful).

### `FileSyncSession.swift`

Inside the `for await chunkMsg in chunkStream` loop, add at the top of the loop body:

```swift
try Task.checkCancellation()
```

In `downloadData()`'s `catch` block, detect `CancellationError` specifically: send the abort ACK, unsubscribe, log "Sync: cancelled by user", rethrow.

In `run()`, after each `downloadData()` call in the per-file loop:

```swift
try Task.checkCancellation()
```

This exits between files rather than starting the next file after a cancel.

### `GarminDeviceManager.swift`

Add a public method (also add to protocol):

```swift
public func cancelSync() async {
    activeSyncTask?.cancel()
    activeSyncTask = nil
}
```

Do NOT send `SYNC_COMPLETE` here — let `FileSyncSession` handle its own cleanup on `CancellationError`.

### `DeviceManagerProtocol.swift`

```swift
func cancelSync() async
```

Add a default no-op extension implementation so `MockGarminDevice` compiles without changes.

### `SyncCoordinator.swift` — `cancelSync()`

After `syncTask?.cancel()`, add:

```swift
await deviceManager.cancelSync()
```

This ensures the inner unstructured `Task` in `pullFITFiles` is cancelled even if Swift's cancellation doesn't propagate through it.

**Acceptance criteria:**
- Tap Cancel; spinner stops within one BLE-chunk round trip (~100 ms)
- UI returns to `.idle`; watch does not hang in transfer-in-progress state
- Subsequent "Sync Now" succeeds without a reconnect

---

## Task 4 — Swipe-to-Delete Confirmation Dialog

**Risk: LOW**

**API note:** `CBCentralManager` has no public API to remove a pairing from the iOS Bluetooth system list. The dialog must inform the user to do this manually.

### `SettingsView.swift`

Add state:

```swift
@State private var showDeleteConfirmation = false
@State private var deviceToDelete: ConnectedDevice? = nil
```

Change the swipe action to set state rather than call `removeDevice` directly:

```swift
.swipeActions(edge: .trailing) {
    Button(role: .destructive) {
        deviceToDelete = device
        showDeleteConfirmation = true
    } label: {
        Label("Remove", systemImage: "trash")
    }
}
```

Add `.confirmationDialog` modifier:

```swift
.confirmationDialog("Remove Watch?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
    Button("Remove", role: .destructive) {
        if let device = deviceToDelete {
            syncCoordinator.removeDevice(device, context: modelContext)
        }
    }
    Button("Cancel", role: .cancel) {}
} message: {
    Text("This will disconnect your Garmin watch and remove it from Compass. To also remove it from iOS Bluetooth, go to Settings → Bluetooth.")
}
```

**Acceptance criteria:**
- Swipe shows confirmation before any action
- Dismissing dialog leaves device listed
- Confirming calls `removeDevice` as before

---

## Task 5 — Settings: Manual Disconnect/Reconnect

**Risk: LOW**

### `SyncCoordinator.swift`

Add two methods:

```swift
func manualDisconnect() async {
    reconnectRetryTask?.cancel()
    reconnectRetryTask = nil
    await deviceManager.disconnect()
    connectionState = .disconnected
    // lastConnectedDevice is preserved — user can reconnect
    AppLogger.sync.info("Manual disconnect")
}

func manualReconnect() async {
    guard lastConnectedDevice != nil else { return }
    startAutoReconnect()
}
```

The key distinction from `removeDevice`: `manualDisconnect` does **not** clear `lastConnectedDevice` and does **not** delete from SwiftData.

### `SettingsView.swift`

In `deviceSection`, below the device name row, add conditional buttons:

```swift
if case .connected = syncCoordinator.connectionState {
    Button("Disconnect") {
        Task { await syncCoordinator.manualDisconnect() }
    }
    .foregroundStyle(.red)
}

if case .disconnected = syncCoordinator.connectionState {
    Button("Reconnect") {
        Task { await syncCoordinator.manualReconnect() }
    }
}
```

**Acceptance criteria:**
- "Disconnect" appears when connected; tapping shows status as "Not connected" without removing device listing
- "Reconnect" appears when disconnected; tapping triggers reconnect flow
- After manual disconnect, auto-reconnect does NOT fire (retry task was cancelled)

---

## Task 6 — BLE Heartbeat

**Risk: MEDIUM**

CoreBluetooth fires `didDisconnectPeripheral` when the BLE supervision timeout expires (typically 6 s). The UI gap is only during that window. The right liveness check is `peripheral.readRSSI()` every 15 s — on failure, the error path triggers `didDisconnect`.

Do NOT use a GFDI-level ping on a timer — this could interfere with active syncs.

### `BluetoothCentral.swift`

Add:

```swift
private var rssiTask: Task<Void, Never>?

func startRSSIPolling() {
    rssiTask?.cancel()
    rssiTask = Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            guard let p = connectedPeripheral else { break }
            p.readRSSI()
        }
    }
}

func stopRSSIPolling() {
    rssiTask?.cancel()
    rssiTask = nil
}
```

In `CentralManagerDelegateAdapter`, implement:

```swift
func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
    if let error {
        central?.didDisconnect(error: error)
    }
}
```

Call `startRSSIPolling()` at the end of `connect()` and `pair()`. Call `stopRSSIPolling()` in `disconnect()`.

**Investigation:** Test that `readRSSI()` calls during heavy chunk transfer do not visibly slow file transfer on the Instinct Solar. The delegate callback is asynchronous and should be low-overhead, but verify on device.

**Acceptance criteria:**
- Turn off watch Bluetooth; within 20 s, UI changes to "Not connected"
- RSSI polling does not measurably slow an active sync

---

## Task 7 — Seamless Reconnect & Persistent Background Connection

**Risk: HIGH** — Requires Task 1 (state restoration) and Task 6 (heartbeat). Test on device only.

### `ConnectionState` enum — new case

Add `case reconnecting` to `ConnectionState` in `CompassBLE`. Update all exhaustive switch sites:
- `SettingsView`: `connectionDotColor` → `.orange`, `connectionStatusLabel` → "Reconnecting…"
- `SyncCoordinator`: treat `.reconnecting` like `.connecting` for sync gating

### `CompassApp.swift` — scene phase observer

```swift
@Environment(\.scenePhase) private var scenePhase

// on WindowGroup body:
.onChange(of: scenePhase) { _, newPhase in
    Task { await syncCoordinator.handleScenePhase(newPhase) }
}
```

### `SyncCoordinator.swift` — background task wrapper for active syncs

Wrap every sync (both phone- and watch-initiated) in a `UIBackgroundTask` so the process gets extended execution time when the screen locks mid-transfer. Without this, iOS suspends the app ~10 seconds after it moves to background, stalling the chunk loop even though BLE notifications keep arriving.

```swift
private var bgTaskID: UIBackgroundTaskIdentifier = .invalid

private func beginBackgroundTask() {
    guard bgTaskID == .invalid else { return }
    bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "com.compass.sync") { [weak self] in
        // Expiry: iOS is about to suspend us — abort cleanly
        self?.cancelSync()
        self?.endBackgroundTask()
    }
}

private func endBackgroundTask() {
    guard bgTaskID != .invalid else { return }
    UIApplication.shared.endBackgroundTask(bgTaskID)
    bgTaskID = .invalid
}
```

Call `beginBackgroundTask()` at the start of `sync()` (phone-initiated) and inside `processWatchInitiatedURLs` before the parse loop. Call `endBackgroundTask()` in the `defer` block of each path. The expiry handler calls `cancelSync()` which (after WP-2 Task 3) sends an abort ACK so the watch doesn't hang.

`UIApplication` is a UIKit type; import it in `SyncCoordinator.swift` via `import UIKit`. This is already an app-layer file so the UIKit dependency is appropriate.

### `SyncCoordinator.swift` — `handleScenePhase`

```swift
func handleScenePhase(_ phase: ScenePhase) async {
    switch phase {
    case .background:
        await deviceManager.notifyBackground()
        // Do NOT disconnect or cancel retry loop.
        // bluetooth-central keeps the BLE connection alive.
        // beginBackgroundTask() on the active sync buys ~30s of CPU execution.
    case .active:
        await deviceManager.notifyForeground()
        if case .disconnected = connectionState {
            startAutoReconnect()
        }
    default:
        break
    }
}
```

### `GarminDeviceManager.swift`

```swift
public func notifyBackground() async {
    guard _isConnected else { return }
    try? await gfdiClient.send(message: SystemEventMessage(eventType: .hostDidEnterBackground).toMessage())
}

public func notifyForeground() async {
    guard _isConnected else { return }
    try? await gfdiClient.send(message: SystemEventMessage(eventType: .hostDidEnterForeground).toMessage())
}
```

Add both to `DeviceManagerProtocol` with default no-op implementations.

### `BluetoothCentral.swift` — auto-reconnect option

Add `CBConnectPeripheralOptionEnableAutoReconnect: true` to the `connect` call (iOS 17+, safe since deployment target is iOS 18):

```swift
centralManager?.connect(peripheral, options: [
    CBConnectPeripheralOptionEnableAutoReconnect: true
])
```

### `startAutoReconnect()` — reconnecting state

When `hasConnectedOnce == true`, yield `.reconnecting` instead of `.connecting` so the UI distinguishes a silent drop from a first-time pair.

**Acceptance criteria:**
- App backgrounded while connected: watch continues to show "phone connected" indicator
- App foregrounded after brief disconnect: reconnects within 15 s with no user action
- `hostDidEnterBackground` and `hostDidEnterForeground` appear in logs at correct times
- Screen locks mid-sync: transfer completes (for syncs under ~40 s total); verify with Instruments Energy Log that background task is claimed and released correctly
- Screen locks mid-sync of a large file (>40 s): expiry handler fires, sync aborts cleanly, watch returns to home screen within 30 s of abort

---

## Protocol Additions Summary

`DeviceManagerProtocol` gains three new methods (all with default no-op extension implementations):

```swift
func cancelSync() async
func notifyBackground() async
func notifyForeground() async
```

`MockGarminDevice` should stub all three.

---

## Known Limitations

- **Unpairing from iOS Bluetooth** — not possible via public CoreBluetooth API. The swipe-to-delete confirmation dialog directs users to Settings → Bluetooth manually.
- **`AsyncStream` mid-transfer hang** — `Task.checkCancellation()` only fires at loop iterations. If the watch stops sending chunks entirely (e.g., goes out of range mid-transfer), the chunk loop will hang waiting for the next element. A `withTaskCancellationHandler` + chunk timeout would be more robust but is lower priority.
- **State restoration empirical testing** — the CLOSE_ALL + ML init on restore must be tested on device before shipping Task 1.

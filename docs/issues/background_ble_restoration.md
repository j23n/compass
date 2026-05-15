# Background BLE: state restoration and lazy central creation

`UIBackgroundModes` in `Compass/Info.plist` lists `bluetooth-central`,
and `BluetoothCentral.swift:168` passes
`CBCentralManagerOptionRestoreIdentifierKey: "com.compass.app.central"`
when constructing the `CBCentralManager`. On paper that means iOS
will wake Compass for incoming notifications on the subscribed
characteristics. In practice the user reports phone-finder doesn't
work when the app is backgrounded and watch-initiated sync never
delivers in background. Two compounding gaps.

## Gap 1: `didRestoreState` tore down the session even on success

`BluetoothCentral.didRestoreState` (line 452) used to fire
`disconnectHandler?(nil)` unconditionally — even after successfully
re-acquiring the peripheral and both characteristics. That triggered
`GarminDeviceManager.handleUnexpectedDisconnect`, which:

1. set `_isConnected = false`
2. yielded `.disconnected` on `connectionStateStream`
3. caused `SyncCoordinator.connectionMonitorTask` to call
   `tearDownDeviceCallbacks()` (clearing
   `watchInitiatedSyncHandler`, `findMyPhoneHandler`,
   `musicCommandHandler`, `weatherProvider`)
4. queued an auto-reconnect that has to redo the whole
   pairing/auth/MLR handshake

iOS only gives the app a brief background wake window (~10 s,
extendable to ~30 s via `beginBackgroundTask`). The full handshake
doesn't finish in that window, so whichever event woke us — the
phone-finder request, the watch-initiated sync trigger — gets
dropped because no handler is registered any more.

**Fixed in this branch.** `didRestoreState` now only fires the
disconnect handler if restoration is incomplete (peripheral
missing, or one of the characteristics not re-acquired). On a full
restore we keep the peripheral and let the existing pump task pick
up whatever notification iOS woke us for. The MLR transport's pump
task and the GFDI receive loop both survive across restoration
because they were started against the actor (not against a specific
session token), so notifications continue to flow.

## Gap 2: `CBCentralManager` is created lazily, after the UI loads

`BluetoothCentral.ensureCentralManager()` (line 158) creates the
manager on first call — which only happens when something invokes
`deviceManager.connect()`. The first such call is
`SyncCoordinator.attemptConnect`, kicked off either by manual
reconnect or by `TodayView`'s `Task { await syncCoordinator.reconnect(device:) }`
(line 273). Both paths require the UI to be running.

When iOS wakes the app for a BLE event in the background, it
delivers `willRestoreState` to whatever `CBCentralManager` exists
with the matching restore identifier — but in our case no manager
exists yet, because the connect call hasn't fired. iOS gives up on
delivering the restoration after a short timeout. By the time
SwiftUI/TodayView spins up far enough to call `reconnect`, the
pending event has been discarded.

For background BLE to actually function, the manager has to be
constructed during `application(_:didFinishLaunchingWithOptions:)`
or its SwiftUI equivalent — synchronously, before any other setup —
and configured with the same restore identifier. SwiftUI app
lifecycle gives this hook through an init that runs on launch; the
issue is that `GarminDeviceManager` doesn't expose a "warm up the
central, register the restore identifier, accept any
state-restoration callback that arrives" entry point that
`CompassApp.init` could call. `attemptConnect` does too much (it
runs the full pair/auth handshake) to fire blindly on every launch.

**Not fixed.** Doing this properly needs:

1. A new `GarminDeviceManager.preflightForRestoration()` (or
   similar) that synchronously triggers `ensureCentralManager()`
   without requiring a paired device or attempting a connect. Call
   it from `CompassApp.init`.
2. `BluetoothCentral` needs to retain the restored peripheral and
   characteristics across the "no current session" period, then
   hand them to the next `connect()` rather than tearing them down.
3. `GarminDeviceManager` needs a path from "central restored with
   live peripheral and active GFDI subscription" to "logical
   connected state" that doesn't re-run the auth handshake.
4. Persist `lastConnectedDevice` (currently an in-memory
   `PairedDevice?` on the coordinator) so the restoration target is
   known on cold launch.

Until all four are in place, Gap 1 being fixed only helps in the
narrow window where the app is still in memory (suspended but not
killed) and gets a wake event before iOS reclaims it.

## Observable symptoms today

| Scenario | Works? |
|---|---|
| Foreground: watch sends WEATHER_REQUEST | ✅ |
| Foreground: phone finder | ✅ |
| Foreground: watch-initiated sync at connect | ✅ |
| Backgrounded but still in memory, BLE wake | ⚠️ partial (now improves with Gap 1 fixed; depends on if connection was still alive at suspension) |
| Backgrounded and reclaimed by iOS, BLE wake | ❌ Gap 2 |

## References

- `Packages/CompassBLE/Sources/CompassBLE/Transport/BluetoothCentral.swift:452-489` (`didRestoreState`)
- `Packages/CompassBLE/Sources/CompassBLE/Transport/BluetoothCentral.swift:158-174` (`ensureCentralManager`)
- `Packages/CompassBLE/Sources/CompassBLE/Public/GarminDeviceManager.swift:161-167` (`handleUnexpectedDisconnect`)
- `Compass/App/SyncCoordinator.swift:107-115` (`connectionMonitorTask`)
- `Compass/App/SyncCoordinator.swift:243` (`lastConnectedDevice` only set on successful pair)
- `Compass/App/SyncCoordinator.swift:274-294` (`startAutoReconnect`)
- `Compass/Info.plist:18-22` (`UIBackgroundModes`)
- Apple docs: CBCentralManagerOptionRestoreIdentifierKey, state preservation/restoration

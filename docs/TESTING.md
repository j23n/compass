# Testing Guide

## Running unit tests

Each Swift package has its own test target. Run tests from the command line or from Xcode.

### Command line

```bash
# Run all tests for a single package
cd Packages/CompassData && swift test
cd Packages/CompassFIT && swift test
cd Packages/CompassBLE && swift test

# Run a specific test case
cd Packages/CompassData && swift test --filter CompassDataTests.CompassDataTests
```

### Xcode

1. Open `Compass.xcodeproj`.
2. Select the scheme for the package you want to test (e.g., `CompassData`).
3. Press Cmd+U to run all tests, or click the diamond next to a specific test in the test navigator.

The app target (`Compass`) does not currently have a test target. UI tests will be added when the core functionality stabilizes.

## Running integration tests

Integration tests live in `Packages/CompassBLE/Tests/CompassBLEIntegrationTests/`. These tests require a physical Garmin device and are not run in CI.

### Setup

1. Pair your Garmin device with your iPhone (or Mac running the test).
2. Ensure Bluetooth is enabled.
3. Set the `COMPASS_INTEGRATION_DEVICE_NAME` environment variable to your device's BLE advertised name.

### Running

```bash
cd Packages/CompassBLE
swift test --filter CompassBLEIntegrationTests
```

Or in Xcode: select the `CompassBLE` scheme and run the `CompassBLEIntegrationTests` test plan.

Integration tests are tagged with a check for the environment variable and will skip gracefully if no device name is set.

## How to capture BLE traffic with PacketLogger

Apple's PacketLogger is the best tool for inspecting raw BLE communication between the iPhone and the fitness watch.

### Prerequisites

- A Mac running macOS 14 or later.
- An iPhone connected via USB.
- Xcode's additional tools installed (PacketLogger is included).
- Download from: Xcode menu -> Open Developer Tool -> More Developer Tools -> "Additional Tools for Xcode" -> Hardware folder -> PacketLogger.app.

### Capture steps

1. **Enable BLE logging on iPhone**:
   - Open Settings -> Developer -> Bluetooth Logging -> Enable.
   - Alternatively, install the Bluetooth logging profile from Apple's developer downloads.

2. **Connect iPhone to Mac via USB**.

3. **Open PacketLogger** on the Mac.

4. **Start capture**: File -> New iOS Trace (or click the iPhone icon in the toolbar). Select your connected device.

5. **Reproduce the sync** in the Compass app (or Garmin Connect, to study the expected behavior).

6. **Stop capture** and save the `.btsnoop` file.

### Analyzing the capture

- Filter by the Garmin service UUID (`6A4E2800`) to isolate relevant traffic.
- Look for ATT Write Request (handle for `6A4E2801`) and ATT Handle Value Notification (handle for `6A4E2802`).
- The first byte of each ATT payload is the MLR flags byte. Reassemble multi-frame messages manually or use a script.
- After reassembly, the first two bytes of each GFDI message are the length, followed by two bytes of message type.

### Tips

- Capture both a Garmin Connect sync and a Compass sync side by side to compare behavior.
- Save captures with descriptive names (e.g., `venu3-auth-2025-01-15.btsnoop`).
- Use Wireshark as an alternative: it can also open `.btsnoop` files and has better filtering.

## Testing against a real device

### Safety notes

- The BLE protocol implementation should never send messages that could modify the watch's settings, delete files, or trigger firmware updates. Compass only reads data.
- Always test with a non-primary device if possible, especially during early protocol development.
- The watch will show a pairing prompt when Compass connects for the first time. This is expected.

### Test workflow

1. **Enable BLE logging** (see above) so you have a capture to debug against.
2. **Launch Compass** in Debug mode (Cmd+R from Xcode with the Debug scheme).
3. **Go to Settings** -> tap "Scan for devices".
4. **Select your watch** from the discovered devices list.
5. **Approve pairing** on the watch when prompted.
6. **Monitor the Xcode console** for log output from `CompassBLE`. The logger (`CompassBLE/Utils/Logger.swift`) uses `os.Logger` with subsystem `com.compass.ble`.
7. **Check sync progress** in the UI -- the Today view should show a sync indicator.

### Log levels

The BLE package uses the following log categories:

| Category      | Content                                           |
|--------------|---------------------------------------------------|
| `transport`  | MLR frame send/receive, raw bytes                  |
| `gfdi`       | GFDI message encode/decode, message types          |
| `auth`       | Authentication handshake steps                     |
| `sync`       | File directory parsing, file transfer progress     |
| `ble`        | CoreBluetooth delegate callbacks, connection state |

Filter in Console.app or Xcode console with: `subsystem:com.compass.ble category:auth`

## Mock data and DEBUG mode

When the app is built with the `DEBUG` compilation condition (the default for Debug builds in Xcode), `SyncCoordinator` bypasses real BLE and populates SwiftData with mock data from `MockDataProvider`.

### What MockDataProvider generates

- 30 days of step count data (varying by day of week)
- 7 days of heart rate samples (1 per 5 minutes, with realistic circadian variation)
- 7 days of body battery samples
- 7 days of stress samples
- 5 recent activities (running, cycling, swimming) with GPS track points
- 3 sleep sessions with stage breakdowns (awake, light, deep, REM)
- HRV nightly averages for the past 14 days
- A mock connected device (simulated Venu 3)

### Controlling mock data

The `MockDataProvider` is deterministic -- it uses a fixed seed so data is reproducible across launches. To generate fresh data, delete the app from the simulator (which clears the SwiftData store) and relaunch.

To disable mock data and test with a real device even in Debug builds, set the `COMPASS_USE_REAL_BLE` environment variable to `1` in the Xcode scheme:

1. Edit Scheme -> Run -> Arguments -> Environment Variables.
2. Add `COMPASS_USE_REAL_BLE` = `1`.
3. Build and run.

### SwiftUI previews

SwiftUI previews use an in-memory `ModelContainer` populated by `MockDataProvider`. Each preview creates its own isolated container so previews do not share state.

Example:
```swift
#Preview {
    TodayView(viewModel: TodayViewModel(
        activityRepository: MockActivityRepository(),
        healthRepository: MockHealthMetricsRepository()
    ))
    .modelContainer(MockDataProvider.previewContainer)
}
```

# Compass

A self-hosted fitness watch companion app for iOS. Compass syncs activity, sleep, and health data from your fitness watch over Bluetooth Low Energy, stores everything locally with SwiftData, and presents it in a clean SwiftUI interface. There is no cloud dependency -- your data never leaves your device.

## Project overview

Compass is structured as a single Xcode project (`Compass.xcodeproj`) with one iOS app target and three local Swift packages:

```
Compass.xcodeproj
Compass/                  iOS app target (SwiftUI)
  App/                    Entry point, sync coordinator, DI container
  Views/                  SwiftUI screens (Today, Activity, Health, Settings)
  ViewModels/             @Observable view models
  Components/             Reusable UI (rings, charts, cards)
  Resources/              Asset catalog, Info.plist (generated)
Packages/
  CompassData/            SwiftData models and repository layer
  CompassFIT/             Garmin FIT file parser with field-name overlay
  CompassBLE/             BLE transport, GFDI framing, file transfer
```

## Build instructions

1. Open `Compass.xcodeproj` in Xcode 16.2 or later.
2. The three local Swift packages resolve automatically (no `swift package resolve` needed).
3. Select an iOS 18.0+ simulator or a physical device.
4. Build and run (Cmd+R).

No external dependencies beyond the Apple SDK. The project uses Swift 6 with strict concurrency checking enabled.

## Module descriptions

### CompassData

The persistence layer. Contains SwiftData `@Model` classes for activities, sleep sessions, heart rate, HRV, stress, respiration, body battery, steps, and connected devices. Each model type has a corresponding repository protocol and concrete implementation that wraps SwiftData queries.

Key files:
- `Models/` -- one file per entity (Activity, SleepSession, HeartRateSample, etc.)
- `Repositories/` -- ActivityRepository, SleepRepository, HealthMetricsRepository, DeviceRepository
- `MockDataProvider.swift` -- generates realistic sample data for previews and DEBUG builds

### CompassFIT

Parses Garmin FIT (Flexible and Interoperable Data Transfer) files into structured Swift types. The parser reads the binary FIT format field-by-field, then applies a human-readable field-name overlay derived from the community FIT SDK documentation.

Key files:
- `Parsers/FITDecoder.swift` -- streaming binary FIT decoder
- `Parsers/FITTimestamp.swift` -- FIT epoch (1989-12-31) to Foundation Date conversion
- `Parsers/MonitoringResults.swift` -- parsed monitoring file output
- `Overlay/FieldNameOverlay.swift` -- maps numeric field IDs to readable names
- `Overlay/HarryOverlayNotes.swift` -- notes on HarryOnline's overlay spreadsheet
- `Resources/harry_overlay.json` -- bundled overlay data

### CompassBLE

Implements the Bluetooth Low Energy transport for communicating with Garmin fitness watches. This includes the MLR (Maximum Likelihood Ratio) framing layer, the GFDI (Garmin Flexible Data Interface) message protocol, authentication handshake, and FIT file transfer.

Key files:
- `Transport/` -- CoreBluetooth central manager wrapper, MLR framing
- `GFDI/` -- message encoding/decoding, message type definitions
- `Auth/` -- device authentication flow
- `Sync/` -- file directory listing and file transfer coordinator
- `Public/` -- protocols and types exposed to the app target (DeviceManagerProtocol, SyncProgress, etc.)
- `Utils/` -- CRC16 checksum, byte reader, logging

## How to fill in the BLE protocol

The BLE protocol implementation is currently stubbed. To build out the real protocol, use Gadgetbridge as the reference implementation:

1. **Clone Gadgetbridge**: `git clone https://codeberg.org/Freeyourgadget/Gadgetbridge.git`

2. **Key source paths**:
   - GFDI message types: `app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/garmin/messages/`
   - MLR transport: `app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/garmin/GarminByteBufferReader.java`
   - Authentication: `app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/garmin/messages/AuthNegotiationMessage.java`
   - File transfer (download): `app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/garmin/FileTransferHandler.java`
   - FIT parsing: `app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/garmin/fit/`
   - Protobuf definitions: `app/src/main/proto/`
   - Device support (Venu, Fenix, etc.): `app/src/main/java/nodomain/freeyourgadget/gadgetbridge/devices/garmin/`

3. **Workflow**:
   - Start with `GarminSupport.java` to understand the connection lifecycle.
   - Trace the authentication handshake in `AuthNegotiationMessage`.
   - Study `FileTransferHandler` for the chunked download protocol.
   - Map each Java `GFDIMessage` subclass to a Swift struct in `CompassBLE/GFDI/Messages/`.

4. **BLE characteristics**:
   - Service UUID: `6A4E2800-667B-11E3-949A-0800200C9A66`
   - Write characteristic: `6A4E2801-667B-11E3-949A-0800200C9A66`
   - Notify characteristic: `6A4E2802-667B-11E3-949A-0800200C9A66`

## How to extend the FIT overlay

The FIT file format uses numeric field definition numbers. The overlay maps these to readable names. To add coverage for new message types or fields:

1. **Reference spreadsheet**: Open HarryOnline's FIT SDK field list at
   `https://docs.google.com/spreadsheets/d/1ukELILJ3FKKHB5UYEbGQUCJ9bS-GnkcJO2HjVLLYnc/` (public, read-only).

2. **Find the message type** in the "Message Types" tab (e.g., message number 55 = `monitoring`).

3. **Find the field** in the corresponding tab. Note the field definition number, type, scale, offset, and units.

4. **Add an entry** to `Packages/CompassFIT/Sources/CompassFIT/Resources/harry_overlay.json`:
   ```json
   {
     "mesgNum": 55,
     "fieldDefNum": 26,
     "fieldName": "current_activity_type_intensity",
     "type": "uint8",
     "scale": null,
     "offset": null,
     "units": null
   }
   ```

5. **Rebuild**. The `FieldNameOverlay` loads the JSON at init time and the new mapping takes effect immediately.

The official Garmin FIT SDK (available on the Garmin developer site) is the canonical reference, but HarryOnline's spreadsheet is more practical for quick lookups because it includes undocumented fields found through reverse engineering.

## TestFlight submission checklist

Before submitting to TestFlight or the App Store:

- [ ] Replace all references to "Garmin" in user-facing strings with "fitness watch" or "compatible device". The word "Garmin" may only appear in code comments and internal identifiers.
- [ ] Ensure `Info.plist` usage descriptions are accurate and do not mention specific device brands.
- [ ] Verify the Bluetooth background mode (`bluetooth-central`) is justified by actual BLE sync functionality, not just declared.
- [ ] Add a privacy manifest (`PrivacyInfo.xcprivacy`) declaring `NSPrivacyAccessedAPICategoryUserDefaults` if UserDefaults is used.
- [ ] Set the correct `DEVELOPMENT_TEAM` in build settings.
- [ ] Increment `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`.
- [ ] Archive with Release configuration and validate in Xcode Organizer before uploading.
- [ ] In App Store Connect metadata, describe Bluetooth usage clearly for App Review.

## Known limitations

- **BLE protocol is stubbed**: The `CompassBLE` package defines the protocol interfaces and data types but does not yet implement the full GFDI handshake or file transfer. The app runs with mock data generated by `MockDataProvider`.
- **Mock data only**: All health metrics, activities, and sleep sessions shown in the UI are synthetic. Real device sync is not yet functional.
- **MapLibre placeholder**: Activity detail views reference a map component for GPS tracks, but the MapLibre integration is not yet wired up. The view currently shows a placeholder.
- **No HealthKit export**: The app stores data in its own SwiftData store. Export to Apple Health via HealthKit is planned but not implemented.
- **Single device pairing**: The data model supports one connected device at a time. Multi-device support is not planned for v1.
- **No watchOS companion**: This is an iPhone-only app. An Apple Watch complication or widget is not in scope.

## License

This project is not yet licensed. All rights reserved.

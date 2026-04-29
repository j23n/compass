# Protobuf Regeneration Guide

Some GFDI messages (types 5004/5005) carry Protocol Buffer encoded payloads. This document explains how to find the `.proto` definitions, generate Swift code, and integrate them into CompassBLE.

## Where to find proto files

The proto files come from the Gadgetbridge repository:

```
https://codeberg.org/Freeyourgadget/Gadgetbridge
```

Path within the repository:

```
app/src/main/proto/
```

Key proto files:

| File                          | Purpose                                          |
|------------------------------|--------------------------------------------------|
| `garmin_vivomovehr.proto`     | Core protobuf message definitions                |
| `device_status.proto`         | Device status and battery reporting               |
| `music_control.proto`         | Music playback control (watch -> phone)           |
| `notification.proto`          | Phone notification push (phone -> watch)          |
| `weather.proto`               | Weather data (phone -> watch)                     |
| `find_my_phone.proto`         | Find my phone trigger                             |
| `settings.proto`              | Device settings sync                              |
| `smart_notifications.proto`   | Smart notification configuration                  |

Not all proto files are needed for Compass. The minimum set for sync functionality is:
- `garmin_vivomovehr.proto` (contains the top-level message wrapper)
- `device_status.proto` (battery level reporting during sync)

Weather and notification protos are only needed if you want to push data to the watch.

## Prerequisites

### Install protoc

The Protocol Buffer compiler:

```bash
# macOS (Homebrew)
brew install protobuf

# Verify
protoc --version
# Should be 3.x or later (28.x as of 2025)
```

### Install swift-protobuf plugin

The Swift code generator plugin:

```bash
# Install via Homebrew
brew install swift-protobuf

# Or build from source
git clone https://github.com/apple/swift-protobuf.git
cd swift-protobuf
swift build -c release
# Copy .build/release/protoc-gen-swift to a directory in your PATH
```

Verify the plugin is accessible:

```bash
protoc-gen-swift --version
# Should print the version number
```

## Regeneration steps

### 1. Get the proto files

```bash
# Clone Gadgetbridge (shallow clone is fine)
git clone --depth 1 https://codeberg.org/Freeyourgadget/Gadgetbridge.git /tmp/gadgetbridge

# Copy proto files to a working directory
mkdir -p /tmp/compass-protos
cp /tmp/gadgetbridge/app/src/main/proto/*.proto /tmp/compass-protos/
```

### 2. Review and adjust proto files

The Gadgetbridge proto files are written for Java/Android. Before generating Swift code:

1. Open each `.proto` file and check the `option java_package` line. This does not affect Swift generation, but review for context.

2. Ensure each file has `syntax = "proto2";` or `syntax = "proto3";` at the top. The Garmin protos typically use proto2.

3. Check for import statements between proto files. If file A imports file B, both must be present when running protoc.

### 3. Generate Swift code

```bash
# Generate .pb.swift files
protoc \
  --swift_out=/tmp/compass-protos/generated \
  --swift_opt=Visibility=Public \
  --proto_path=/tmp/compass-protos \
  /tmp/compass-protos/*.proto
```

Options explained:
- `--swift_out`: Output directory for generated `.pb.swift` files.
- `--swift_opt=Visibility=Public`: Makes generated types `public` so they are accessible from other modules.
- `--proto_path`: Directory where protoc looks for imported proto files.

### 4. Copy generated files into CompassBLE

```bash
# Target directory
DEST=Packages/CompassBLE/Sources/CompassBLE/GFDI/Messages/Proto

# Create if needed
mkdir -p "$DEST"

# Copy generated files
cp /tmp/compass-protos/generated/*.pb.swift "$DEST/"
```

### 5. Add SwiftProtobuf dependency

The generated `.pb.swift` files depend on the `SwiftProtobuf` runtime library. Add it to the CompassBLE package:

In `Packages/CompassBLE/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CompassBLE",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "CompassBLE", targets: ["CompassBLE"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
    ],
    targets: [
        .target(
            name: "CompassBLE",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "CompassBLETests",
            dependencies: ["CompassBLE"]
        ),
    ]
)
```

### 6. Build and verify

```bash
cd Packages/CompassBLE
swift build
```

Fix any compilation errors. Common issues:
- **Missing imports**: Add `import SwiftProtobuf` at the top of any file that references protobuf types.
- **Naming conflicts**: Protobuf-generated Swift types use the proto message name. If a name conflicts with a CompassBLE type, use the fully qualified name (e.g., `GarminVivomoveHr_SomeMessage`).
- **Proto2 optionals**: Proto2 fields are optional by default in the generated Swift code. Handle `nil` cases appropriately.

## Which proto messages are needed

For the initial Compass implementation, only a subset of proto messages is required:

### Required for sync

| Proto message                         | Usage                                      |
|--------------------------------------|--------------------------------------------|
| `ProtobufRequestPayload`             | Top-level wrapper for phone -> watch       |
| `ProtobufResponsePayload`            | Top-level wrapper for watch -> phone       |
| `DeviceStatusProtobufMessage`        | Battery level, charging state              |

### Optional (future features)

| Proto message                         | Usage                                      |
|--------------------------------------|--------------------------------------------|
| `WeatherConditionsProtobufMessage`    | Push weather to watch                      |
| `MusicControlProtobufMessage`        | Music playback controls                     |
| `NotificationProtobufMessage`        | Push phone notifications                    |
| `FindMyPhoneProtobufMessage`         | Find my phone ring                          |
| `CalendarProtobufMessage`            | Push calendar events                        |

### Not needed

- Firmware update related messages
- Workout plan push messages
- Connect IQ app management messages

## Keeping protos up to date

When Gadgetbridge updates their proto files (usually when new device support is added):

1. Pull the latest Gadgetbridge source.
2. Diff the proto files against your local copies.
3. Regenerate only the changed files.
4. Rebuild and test.

Proto changes are infrequent. The core message structure has been stable across multiple Garmin device generations.

## Troubleshooting

### protoc-gen-swift not found

Ensure the plugin binary is in your `PATH`:

```bash
which protoc-gen-swift
```

If installed via Homebrew, it should be at `/opt/homebrew/bin/protoc-gen-swift`. If built from source, ensure the binary location is in your `PATH`.

### Import resolution failures

If protoc cannot resolve imports between proto files, ensure all referenced proto files are in the `--proto_path` directory and that import paths in the `.proto` files match the relative file locations.

### Generated code does not compile

Ensure your `swift-protobuf` runtime version matches the `protoc-gen-swift` plugin version. Mismatched versions can produce incompatible code.

```bash
# Check plugin version
protoc-gen-swift --version

# Ensure Package.swift dependency matches
# .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0")
```

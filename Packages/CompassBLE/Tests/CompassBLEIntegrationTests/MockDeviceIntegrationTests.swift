import Testing
import Foundation
@testable import CompassBLE

/// Integration tests for the mock Garmin device.
///
/// These tests exercise the full mock flow: discover, pair, pull files.
/// They verify that the mock implementation correctly simulates the protocol
/// and produces usable output.

import Synchronization

/// Thread-safe accumulator for progress updates, used in tests.
private final class ProgressAccumulator: Sendable {
    private let _updates = Mutex<[String]>([])

    func append(_ update: SyncProgress) {
        _updates.withLock { $0.append("\(update)") }
    }

    var descriptions: [String] {
        _updates.withLock { Array($0) }
    }

    var isEmpty: Bool {
        _updates.withLock { $0.isEmpty }
    }
}

@Suite("MockGarminDevice Integration Tests")
struct MockDeviceIntegrationTests {

    @Test("Full discovery to file pull flow")
    func fullFlow() async throws {
        let mock = MockGarminDevice(config: .init(
            filesPerDirectory: 2,
            fileSizeBytes: 1024
        ))

        // Step 1: Discover
        var discoveredDevice: DiscoveredDevice?
        for await device in mock.discover() {
            discoveredDevice = device
            break // Take the first one
        }

        let device = try #require(discoveredDevice)
        #expect(device.name == "Forerunner 265")
        #expect(device.rssi == -55)

        // Step 2: Pair
        let paired = try await mock.pair(device)
        #expect(paired.name == device.name)
        #expect(paired.model == "Garmin Forerunner 265")
        #expect(paired.identifier == device.identifier)

        // Step 3: Verify connected
        let connected = await mock.isConnected
        #expect(connected)

        // Step 4: Pull files with progress tracking
        let accumulator = ProgressAccumulator()
        let (progressStream, progressContinuation) = AsyncStream<SyncProgress>.makeStream()

        let progressTask = Task {
            for await update in progressStream {
                accumulator.append(update)
            }
        }

        let urls = try await mock.pullFITFiles(
            directories: [.activity],
            progress: progressContinuation
        )
        progressContinuation.finish()
        await progressTask.value

        // Verify files
        #expect(urls.count == 2)
        for tuple in urls {
            let url = tuple.url
            #expect(url.pathExtension == "fit")
            let data = try Data(contentsOf: url)
            #expect(data.count == 1024)

            // Verify FIT header signature
            #expect(data[0] == 14) // Header size
            #expect(data[8] == 0x2E) // '.'
            #expect(data[9] == 0x46) // 'F'
            #expect(data[10] == 0x49) // 'I'
            #expect(data[11] == 0x54) // 'T'
        }

        // Verify progress updates
        let descriptions = accumulator.descriptions
        #expect(!descriptions.isEmpty)
        // Should contain: starting, listing, downloading..., parsing, completed
        #expect(descriptions.first == "SyncProgress.starting")
        #expect(descriptions.contains(where: { $0.contains("listing") }))
        #expect(descriptions.contains(where: { $0.contains("downloading") }))
        #expect(descriptions.last?.contains("completed") == true)

        // Cleanup temp files
        for tuple in urls {
            try? FileManager.default.removeItem(at: tuple.url)
        }
    }

    @Test("Discovery yields no devices when configured to fail")
    func discoveryFails() async throws {
        let mock = MockGarminDevice(config: .init(failDiscovery: true))

        var devices: [DiscoveredDevice] = []
        for await device in mock.discover() {
            devices.append(device)
        }

        #expect(devices.isEmpty)
    }

    @Test("Pairing fails when configured")
    func pairingFails() async throws {
        let mock = MockGarminDevice(config: .init(failPairing: true))

        let device = DiscoveredDevice(
            identifier: UUID(),
            name: "Test Device",
            rssi: -60
        )

        do {
            _ = try await mock.pair(device)
            Issue.record("Should have thrown PairingError.pairingRejected")
        } catch let error as PairingError {
            if case .pairingRejected = error {
                // Expected
            } else {
                Issue.record("Wrong error case: \(error)")
            }
        }
    }

    @Test("Auth failure during pairing")
    func authFailure() async throws {
        let mock = MockGarminDevice(config: .init(failAuth: true))

        let device = DiscoveredDevice(
            identifier: UUID(),
            name: "Test Device",
            rssi: -60
        )

        do {
            _ = try await mock.pair(device)
            Issue.record("Should have thrown PairingError.authenticationFailed")
        } catch let error as PairingError {
            if case .authenticationFailed = error {
                // Expected
            } else {
                Issue.record("Wrong error case: \(error)")
            }
        }
    }

    @Test("Sync fails when configured")
    func syncFails() async throws {
        let mock = MockGarminDevice(config: .init(failSync: true))

        // Pair first (need to be connected)
        let device = DiscoveredDevice(
            identifier: UUID(),
            name: "Test Device",
            rssi: -60
        )
        _ = try await mock.pair(device)

        let (_, progressContinuation) = AsyncStream<SyncProgress>.makeStream()

        do {
            _ = try await mock.pullFITFiles(
                directories: [.activity],
                progress: progressContinuation
            )
            Issue.record("Should have thrown")
        } catch {
            // Expected — sync was configured to fail
        }

        progressContinuation.finish()
    }

    @Test("Pull files from multiple directories")
    func multipleDirectories() async throws {
        let mock = MockGarminDevice(config: .init(
            filesPerDirectory: 1,
            fileSizeBytes: 512
        ))

        let device = DiscoveredDevice(
            identifier: UUID(),
            name: "Test",
            rssi: -50
        )
        _ = try await mock.pair(device)

        let urls = try await mock.pullFITFiles(
            directories: [.activity, .monitor, .sleep],
            progress: nil
        )

        // 1 file per directory x 3 directories = 3 files
        #expect(urls.count == 3)

        // Cleanup
        for tuple in urls {
            try? FileManager.default.removeItem(at: tuple.url)
        }
    }

    @Test("Disconnect clears connected state")
    func disconnectClears() async throws {
        let mock = MockGarminDevice()

        let device = DiscoveredDevice(
            identifier: UUID(),
            name: "Test",
            rssi: -50
        )
        _ = try await mock.pair(device)
        #expect(await mock.isConnected)

        await mock.disconnect()
        #expect(await mock.isConnected == false)
    }

    @Test("Pull files fails when not connected")
    func pullFilesNotConnected() async throws {
        let mock = MockGarminDevice()

        do {
            _ = try await mock.pullFITFiles(directories: [.activity], progress: nil)
            Issue.record("Should have thrown")
        } catch let error as PairingError {
            if case .bluetoothUnavailable = error {
                // Expected
            } else {
                Issue.record("Wrong error: \(error)")
            }
        }
    }

    @Test("Upload course when connected")
    func uploadCourse() async throws {
        let mock = MockGarminDevice()

        let device = DiscoveredDevice(
            identifier: UUID(),
            name: "Test",
            rssi: -50
        )
        _ = try await mock.pair(device)

        // Create a temp file to upload
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_course_\(UUID().uuidString).fit")
        try Data([0x0E, 0x20]).write(to: tempURL)

        _ = try await mock.uploadCourse(tempURL)
        // Should complete without error

        try? FileManager.default.removeItem(at: tempURL)
    }

    @Test("Upload course fails when not connected")
    func uploadCourseNotConnected() async throws {
        let mock = MockGarminDevice()

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_course_\(UUID().uuidString).fit")

        do {
            _ = try await mock.uploadCourse(tempURL)
            Issue.record("Should have thrown")
        } catch let error as PairingError {
            if case .bluetoothUnavailable = error {
                // Expected
            } else {
                Issue.record("Wrong error: \(error)")
            }
        }
    }

    @Test("Reconnect to previously paired device")
    func reconnect() async throws {
        let mock = MockGarminDevice()

        let device = DiscoveredDevice(
            identifier: UUID(),
            name: "Test",
            rssi: -50
        )
        let paired = try await mock.pair(device)
        await mock.disconnect()
        #expect(await mock.isConnected == false)

        try await mock.connect(paired)
        #expect(await mock.isConnected)
    }

    @Test("Custom device name and model in config")
    func customDeviceInfo() async throws {
        let mock = MockGarminDevice(config: .init(
            deviceName: "Venu 3",
            deviceModel: "Garmin Venu 3"
        ))

        var discoveredDevice: DiscoveredDevice?
        for await device in mock.discover() {
            discoveredDevice = device
            break
        }

        let device = try #require(discoveredDevice)
        #expect(device.name == "Venu 3")

        let paired = try await mock.pair(device)
        #expect(paired.model == "Garmin Venu 3")
    }
}

import SwiftUI
import SwiftData
import CompassData
import CompassBLE

/// Settings sheet with device management, sync controls, and about information.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncCoordinator.self) private var syncCoordinator

    @Query(sort: \ConnectedDevice.name)
    private var connectedDevices: [ConnectedDevice]

    private var device: ConnectedDevice? {
        connectedDevices.first
    }

    private var isSyncing: Bool {
        if case .syncing = syncCoordinator.state { return true }
        return false
    }

    private var connectionDotColor: Color {
        switch syncCoordinator.connectionState {
        case .connected: .green
        case .connecting: .orange
        case .disconnected, .failed: .gray
        }
    }

    private var connectionStatusLabel: String {
        switch syncCoordinator.connectionState {
        case .connected: "Connected"
        case .connecting: "Connecting..."
        case .disconnected: "Not connected"
        case .failed: "Connection failed"
        }
    }

    private var connectionStatusColor: Color {
        switch syncCoordinator.connectionState {
        case .connected: .green
        case .connecting: .orange
        case .disconnected, .failed: .secondary
        }
    }

    var body: some View {
        @Bindable var coordinator = syncCoordinator

        NavigationStack {
            List {
                deviceSection

                syncSection

                if device != nil {
                    warningSection
                }

                developerSection

                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        AppLogger.ui.debug("Settings dismissed")
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $coordinator.showPairingSheet, onDismiss: {
                AppLogger.ui.debug("Pairing sheet dismissed")
                syncCoordinator.cancelPairing()
            }) {
                PairingSheet()
            }
        }
    }

    // MARK: - Device Section

    @ViewBuilder
    private var deviceSection: some View {
        Section {
            if let device {
                HStack(spacing: 12) {
                    Image(systemName: "applewatch")
                        .font(.title2)
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .font(.body)
                            .fontWeight(.medium)

                        Text(connectionStatusLabel)
                            .font(.caption)
                            .foregroundStyle(connectionStatusColor)
                    }

                    Spacer()

                    Circle()
                        .fill(connectionDotColor)
                        .frame(width: 10, height: 10)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        Task { await syncCoordinator.removeDevice(device, context: modelContext) }
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }

                if let lastSync = device.lastSyncedAt {
                    HStack {
                        Text("Last synced")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(lastSync, style: .relative)
                            .foregroundStyle(.secondary)
                            + Text(" ago")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            } else {
                HStack {
                    Image(systemName: "applewatch.slash")
                        .font(.title2)
                        .foregroundStyle(.secondary)

                    Text("No device connected")
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                AppLogger.ui.info("Pair button tapped")
                syncCoordinator.startPairing()
            } label: {
                Label(
                    device == nil ? "Pair a Device" : "Pair New Device",
                    systemImage: "plus.circle"
                )
            }
        } header: {
            Text("Connected Device")
        }
    }

    // MARK: - Sync Section

    @ViewBuilder
    private var syncSection: some View {
        Section {
            Button {
                AppLogger.ui.info("Sync Now tapped")
                syncCoordinator.sync(context: modelContext)
            } label: {
                HStack {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if isSyncing {
                        ProgressView()
                        Button("Cancel", role: .destructive) {
                            syncCoordinator.cancelSync()
                        }
                        .font(.caption)
                    }
                }
            }
            .disabled(device == nil || isSyncing)

            // Sync state description
            switch syncCoordinator.state {
            case .syncing(let description):
                HStack {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if syncCoordinator.progress > 0 {
                        Text("\(Int(syncCoordinator.progress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            case .completed(let fileCount):
                Text("Synced \(fileCount) files")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            case .idle:
                EmptyView()
            }

            if let lastSync = syncCoordinator.lastSyncDate {
                HStack {
                    Text("Last sync")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(lastSync, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        } header: {
            Text("Sync")
        }
    }

    // MARK: - Warning Section

    @ViewBuilder
    private var warningSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.title3)

                Text("Your watch is paired with Compass using unofficial credentials. Reconnecting to the official app may require a factory reset.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.yellow.opacity(0.08))
        }
    }

    // MARK: - Developer Section

    @ViewBuilder
    private var developerSection: some View {
        Section {
            NavigationLink {
                LogsView()
            } label: {
                Label("Logs", systemImage: "doc.text.magnifyingglass")
            }

            NavigationLink {
                FITFilesView()
            } label: {
                Label("FIT Files", systemImage: "doc.badge.arrow.up")
            }
        } header: {
            Text("Developer")
        }
    }

    // MARK: - About Section

    @ViewBuilder
    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text("1.0.0")
                    .foregroundStyle(.secondary)
            }

            NavigationLink {
                acknowledgementsView
            } label: {
                Text("Acknowledgements")
            }
        } header: {
            Text("About")
        }
    }

    @ViewBuilder
    private var acknowledgementsView: some View {
        List {
            Section {
                Text("Compass is an open-source fitness watch companion app.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Open Source Libraries") {
                acknowledgementRow(name: "Swift Charts", detail: "Apple Inc.")
                acknowledgementRow(name: "SwiftData", detail: "Apple Inc.")
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func acknowledgementRow(name: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.body)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Pairing Sheet

/// Sheet shown during device discovery and pairing.
struct PairingSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncCoordinator.self) private var syncCoordinator

    var body: some View {
        NavigationStack {
            Group {
                switch syncCoordinator.pairingState {
                case .scanning:
                    scanningView
                case .pairing(let deviceName):
                    pairingProgressView(deviceName: deviceName)
                case .paired:
                    pairedSuccessView
                case .failed(let message):
                    failedView(message: message)
                case .idle:
                    EmptyView()
                }
            }
            .navigationTitle("Pair Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        AppLogger.ui.debug("Pairing cancelled by user")
                        syncCoordinator.cancelPairing()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var scanningView: some View {
        VStack(spacing: 0) {
            if syncCoordinator.discoveredDevices.isEmpty {
                ContentUnavailableView {
                    Label("Scanning...", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text("Make sure your Garmin watch is nearby and in pairing mode.")
                }
                .overlay(alignment: .top) {
                    ProgressView()
                        .padding(.top, 20)
                }
            } else {
                List(syncCoordinator.discoveredDevices) { device in
                    Button {
                        AppLogger.ui.info("User selected device: \(device.name)")
                        Task {
                            await syncCoordinator.pairDevice(device, context: modelContext)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "applewatch")
                                .font(.title2)
                                .foregroundStyle(.blue)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .font(.body)
                                    .fontWeight(.medium)

                                Text("Signal: \(device.rssi) dBm")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)
                }
            }
        }
    }

    @ViewBuilder
    private func pairingProgressView(deviceName: String) -> some View {
        ContentUnavailableView {
            Label("Pairing...", systemImage: "link.circle")
        } description: {
            Text("Connecting to \(deviceName). Accept the pairing request on your watch if prompted.")
        }
        .overlay(alignment: .top) {
            ProgressView()
                .padding(.top, 20)
        }
    }

    @ViewBuilder
    private var pairedSuccessView: some View {
        ContentUnavailableView {
            Label("Paired!", systemImage: "checkmark.circle.fill")
        } description: {
            Text("Your device is connected and ready to sync.")
        }
    }

    @ViewBuilder
    private func failedView(message: String) -> some View {
        ContentUnavailableView {
            Label("Pairing Failed", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                AppLogger.ui.info("User retrying pairing")
                syncCoordinator.startPairing()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    SettingsView()
        .environment(SyncCoordinator(deviceManager: MockGarminDevice()))
        .modelContainer(for: [ConnectedDevice.self], inMemory: true)
}

import SwiftUI
import SwiftData
import CompassBLE
import CompassData

/// Centered navigation-bar status indicator showing device name,
/// connection state, and live sync progress.
struct ConnectionSyncStatusView: View {
    @Environment(SyncCoordinator.self) private var sync

    /// Drives the pulse animation. We don't read time directly — the
    /// `.task(id:)` modifier kicks this on every `watchActivityPulseCount`
    /// increment and SwiftUI re-evaluates the body.
    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.0

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                connectionDot
                Text(deviceLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            secondaryRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .frame(maxWidth: 320)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    /// Connection-state dot with a single-shot scale+fade ring on each watch
    /// activity event. The ring is invisible at rest (opacity 0), so the dot
    /// looks identical to a plain circle when nothing is happening.
    private var connectionDot: some View {
        ZStack {
            Circle()
                .stroke(connectionDotColor, lineWidth: 1.5)
                .scaleEffect(pulseScale)
                .opacity(pulseOpacity)
                .frame(width: 9, height: 9)
            Circle()
                .fill(connectionDotColor)
                .frame(width: 9, height: 9)
        }
        .frame(width: 9, height: 9)
        .task(id: sync.watchActivityPulseCount) {
            guard sync.watchActivityPulseCount > 0 else { return }
            // Reset without animation so the next withAnimation block has a
            // clean starting state — otherwise SwiftUI coalesces the reset and
            // the target into one transaction and the ring "appears" already
            // half-faded.
            withTransaction(Transaction(animation: nil)) {
                pulseScale = 1.0
                pulseOpacity = 0.7
            }
            withAnimation(.easeOut(duration: 0.7)) {
                pulseScale = 3.0
                pulseOpacity = 0.0
            }
        }
    }

    @ViewBuilder
    private var secondaryRow: some View {
        if isSyncing {
            HStack(spacing: 6) {
                if sync.progress > 0 {
                    ProgressView(value: sync.progress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        .frame(width: 70)
                } else {
                    ProgressView().controlSize(.mini).tint(.secondary)
                }
                Text(syncDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            Text(connectionStatusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var isSyncing: Bool {
        if case .syncing = sync.state { return true }
        return false
    }

    private var deviceLabel: String {
        if case .connected(let name) = sync.connectionState { return name }
        if let name = sync.lastKnownDeviceName { return name }
        return "No device"
    }

    private var connectionStatusText: String {
        switch sync.connectionState {
        case .connected:        "Connected"
        case .connecting:       "Connecting…"
        case .reconnecting:     "Reconnecting…"
        case .disconnected:     "Not connected"
        case .failed(let msg):  msg.isEmpty ? "Connection failed" : "Failed: \(msg)"
        }
    }

    private var syncDetail: String {
        guard case .syncing(let desc) = sync.state else { return "" }
        if let bytes = sync.transferBytes, let total = bytes.total, total > 0 {
            return "\(Int(sync.progress * 100))% · \(byteString(bytes.received)) / \(byteString(total))"
        }
        if sync.progress > 0 { return "\(Int(sync.progress * 100))%" }
        return abbreviated(desc)
    }

    private var connectionDotColor: Color {
        switch sync.connectionState {
        case .connected:                .green
        case .connecting, .reconnecting: .orange
        case .disconnected, .failed:    .gray
        }
    }

    private func abbreviated(_ s: String) -> String {
        let trimmed = s.replacingOccurrences(of: " files...", with: "…")
                       .replacingOccurrences(of: "...", with: "…")
        return trimmed.count > 28 ? String(trimmed.prefix(27)) + "…" : trimmed
    }

    private func byteString(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB, .useBytes]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private var accessibilityDescription: String {
        let secondary = isSyncing ? syncDetail : connectionStatusText
        return "\(deviceLabel), \(secondary)"
    }
}

// MARK: - View modifier

extension View {
    /// Adds the global connection / sync indicator centered in the
    /// nearest navigation bar. Apply once on the root view of each tab's NavigationStack.
    func connectionStatusToolbar() -> some View {
        toolbar {
            ToolbarItem(placement: .principal) {
                ConnectionSyncStatusView()
            }
        }
    }
}

#Preview {
    NavigationStack {
        Text("Preview")
            .navigationTitle("Test")
            .connectionStatusToolbar()
    }
    .environment(SyncCoordinator(
        deviceManager: MockGarminDevice(),
        modelContainer: try! ModelContainer(
            for: ConnectedDevice.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    ))
}

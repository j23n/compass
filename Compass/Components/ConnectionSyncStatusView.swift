import SwiftUI
import SwiftData
import CompassBLE
import CompassData

/// Compact status indicator for the navigation bar.
/// Sync-in-progress takes precedence over connection state.
struct ConnectionSyncStatusView: View {
    @Environment(SyncCoordinator.self) private var sync

    var body: some View {
        HStack(spacing: 6) {
            statusDot
            Text(primaryLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let secondary = secondaryLabel {
                Text("·").foregroundStyle(.tertiary)
                HStack(spacing: 4) {
                    if isSyncing {
                        ProgressView().controlSize(.mini).tint(.secondary)
                    }
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .frame(maxWidth: 220, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var statusDot: some View {
        Circle().fill(connectionDotColor).frame(width: 8, height: 8)
    }

    private var isSyncing: Bool {
        if case .syncing = sync.state { return true }
        return false
    }

    private var primaryLabel: String {
        if case .failed = sync.state { return "Sync failed" }
        return connectionLabel
    }

    private var secondaryLabel: String? {
        switch sync.state {
        case .syncing(let desc):
            if let bytes = sync.transferBytes {
                return "\(byteString(bytes.received)) / \(byteString(bytes.total ?? 0))"
            }
            if sync.progress > 0 { return "\(Int(sync.progress * 100))%" }
            return abbreviated(desc)
        default:
            return nil
        }
    }

    private var connectionDotColor: Color {
        switch sync.connectionState {
        case .connected:                .green
        case .connecting, .reconnecting: .orange
        case .disconnected, .failed:    .gray
        }
    }

    private var connectionLabel: String {
        switch sync.connectionState {
        case .connected(let name): name
        case .connecting:          "Connecting…"
        case .reconnecting:        "Reconnecting…"
        case .disconnected:        "Not connected"
        case .failed:              "Connection failed"
        }
    }

    private func abbreviated(_ s: String) -> String {
        let trimmed = s.replacingOccurrences(of: " files...", with: "…")
                       .replacingOccurrences(of: "...", with: "…")
        return trimmed.count > 24 ? String(trimmed.prefix(23)) + "…" : trimmed
    }

    private func byteString(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB, .useBytes]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private var accessibilityDescription: String {
        if let secondary = secondaryLabel {
            return "\(primaryLabel), \(secondary)"
        }
        return primaryLabel
    }
}

// MARK: - View modifier

extension View {
    /// Adds the global connection / sync indicator to the leading edge of the
    /// nearest navigation bar. Apply once on the root view of each tab's NavigationStack.
    func connectionStatusToolbar() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarLeading) {
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

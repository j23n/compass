import SwiftUI
import SwiftData
import CompassBLE
import CompassData

/// Compact status indicator for the navigation bar.
/// Sync-in-progress takes precedence over connection state.
struct ConnectionSyncStatusView: View {
    @Environment(SyncCoordinator.self) private var sync

    var body: some View {
        HStack(spacing: 5) {
            switch displayMode {
            case .syncing(let label):
                ProgressView()
                    .controlSize(.mini)
                    .tint(.secondary)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Text("Sync failed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

            case .connection(let dot, let label):
                Circle().fill(dot).frame(width: 8, height: 8)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Display mode resolution

    private enum Mode {
        case syncing(label: String)
        case failed
        case connection(dot: Color, label: String)
    }

    private var displayMode: Mode {
        if case .syncing(let desc) = sync.state {
            let label: String
            if sync.progress > 0 {
                label = "\(Int(sync.progress * 100))%"
            } else {
                label = abbreviated(desc)
            }
            return .syncing(label: label)
        }
        if case .failed = sync.state { return .failed }
        return .connection(dot: connectionDotColor, label: connectionLabel)
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

    /// "Listing activity files…" → "Listing activity…"
    /// Bounded to ~24 visible chars so the toolbar item never pushes the title.
    private func abbreviated(_ s: String) -> String {
        let trimmed = s.replacingOccurrences(of: " files...", with: "…")
                       .replacingOccurrences(of: "...", with: "…")
        return trimmed.count > 24 ? String(trimmed.prefix(23)) + "…" : trimmed
    }

    private var accessibilityDescription: String {
        switch displayMode {
        case .syncing(let l): return "Syncing, \(l)"
        case .failed:         return "Sync failed"
        case .connection(_, let label): return "Watch: \(label)"
        }
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

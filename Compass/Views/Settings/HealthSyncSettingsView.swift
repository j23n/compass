import SwiftUI
import CompassHealth

/// Settings section for the Apple Health one-way sync. Owns the toggle,
/// status line, and "Resync All" / "Open in Health" buttons.
struct HealthSyncSettingsView: View {
    @Environment(HealthKitSyncService.self) private var healthSync

    var body: some View {
        if !healthSync.isAvailable {
            Section("Apple Health") {
                Text("Apple Health is not available on this device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            Section {
                Toggle("Sync to Apple Health", isOn: enabledBinding)

                if healthSync.isEnabled {
                    statusRow

                    Button {
                        AppLogger.ui.info("User tapped Resync All to Apple Health")
                        healthSync.runFullReconcile()
                    } label: {
                        HStack {
                            Label("Resync All", systemImage: "arrow.clockwise.heart")
                            Spacer()
                            if healthSync.isRunning {
                                ProgressView().controlSize(.small)
                                Button("Cancel", role: .destructive) {
                                    healthSync.cancel()
                                }
                                .font(.caption)
                            }
                        }
                    }
                    .disabled(healthSync.isRunning)

                    Button {
                        if let url = URL(string: "x-apple-health://") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Open Health App", systemImage: "heart.text.square")
                    }
                }
            } header: {
                Text("Apple Health")
            } footer: {
                if healthSync.isEnabled {
                    Text("Compass writes workouts, sleep, heart rate, respiration, blood oxygen, steps, and active minutes to Apple Health. Stress, Body Battery, and HRV are not supported by HealthKit.")
                } else {
                    Text("Toggle on to mirror everything Compass collects into the Health app. HealthKit retains the data even after you toggle off.")
                }
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { healthSync.isEnabled },
            set: { newValue in
                if newValue {
                    healthSync.enable()
                } else {
                    healthSync.disable()
                }
            }
        )
    }

    @ViewBuilder
    private var statusRow: some View {
        switch healthSync.phase {
        case .running(let done, let total, let label):
            HStack {
                ProgressView().controlSize(.small).tint(.pink)
                Text(label)
                    .font(.subheadline)
                Spacer()
                if total > 0 {
                    Text("\(done) / \(total)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last export failed")
                        .font(.subheadline)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        case .succeeded, .idle, .cancelled:
            if let last = healthSync.lastSuccessfulExport {
                HStack {
                    Text("Last sync").foregroundStyle(.secondary)
                    Spacer()
                    Text(last, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)

                if let summary = healthSync.lastSummary, summary.totalAdded > 0 {
                    Text(summaryCaption(summary))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Not synced yet").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func summaryCaption(_ summary: ExportSummary) -> String {
        var parts: [String] = []
        if summary.workoutsAdded > 0 { parts.append("\(summary.workoutsAdded) workouts") }
        if summary.routesAdded > 0   { parts.append("\(summary.routesAdded) routes") }
        if summary.sleepStagesAdded > 0 { parts.append("\(summary.sleepStagesAdded) sleep stages") }
        if summary.quantitySamplesAdded > 0 { parts.append("\(summary.quantitySamplesAdded) samples") }
        return "Exported \(parts.joined(separator: ", "))"
    }
}

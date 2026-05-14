import SwiftUI
import CompassFIT

/// Confirmation sheet shown when a course being imported looks like one
/// the user already has (same name + similar total distance).
struct DuplicateImportSheet: View {
    let pending: CourseImportCoordinator.PendingImport
    let onResolve: (CourseImporter.DuplicateResolution?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("You already have a course that looks like this one. What would you like to do?")
                        .font(.callout)
                }
                if let existing = pending.prepared.duplicateSummary {
                    Section("Existing") {
                        LabeledContent("Name", value: existing.name)
                        LabeledContent("Distance", value: String(format: "%.2f km", existing.totalDistance / 1_000))
                        LabeledContent("Imported", value: existing.importDate.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                Section("Incoming") {
                    LabeledContent("Name", value: pending.prepared.parsed.name)
                    LabeledContent("Distance", value: String(format: "%.2f km", pending.prepared.parsed.totalDistance / 1_000))
                    LabeledContent("Waypoints", value: "\(pending.prepared.parsed.waypoints.count)")
                }
                Section {
                    Button {
                        onResolve(.overwrite)
                        dismiss()
                    } label: {
                        Label("Replace existing", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button {
                        onResolve(.duplicate)
                        dismiss()
                    } label: {
                        Label("Keep both", systemImage: "plus.square.on.square")
                    }
                } footer: {
                    Text("Replacing discards any edits you made to POI icons or names on the existing course.")
                        .font(.caption)
                }
            }
            .navigationTitle("Duplicate Course")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onResolve(nil)
                        dismiss()
                    }
                }
            }
        }
    }
}

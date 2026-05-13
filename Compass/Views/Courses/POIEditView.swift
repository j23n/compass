import SwiftUI
import CompassData

/// Edits a single course POI: name + icon type (FIT `course_point.type`).
///
/// Pattern matches `CourseEditView` — sheet with a Form, draft state,
/// Save / Cancel toolbar buttons.
struct POIEditView: View {
    let poi: CoursePOI
    @Environment(\.dismiss) private var dismiss

    @State private var draftName: String
    @State private var draftType: CoursePointType

    init(poi: CoursePOI) {
        self.poi = poi
        _draftName = State(initialValue: poi.name)
        _draftType = State(initialValue: CoursePointType(fitCode: UInt8(clamping: poi.coursePointType)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("POI name", text: $draftName)
                        .textInputAutocapitalization(.words)
                }
                Section("Icon") {
                    Picker("Icon", selection: $draftType) {
                        ForEach(CoursePointType.allCases, id: \.self) { type in
                            Label(type.displayName, systemImage: type.systemImage)
                                .tag(type)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
                Section {
                    LabeledContent("Distance") {
                        Text(String(format: "%.2f km", poi.distanceFromStart / 1_000))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Edit POI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(saveDisabled)
                }
            }
        }
    }

    private var saveDisabled: Bool {
        draftName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { poi.name = trimmed }
        poi.coursePointType = Int(draftType.fitCode)
        dismiss()
    }
}

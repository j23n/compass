import SwiftUI
import CompassData

struct CourseEditView: View {
    let course: Course
    @Environment(\.dismiss) private var dismiss

    @State private var draftName: String
    @State private var draftSport: Sport

    init(course: Course) {
        self.course = course
        _draftName  = State(initialValue: course.name)
        _draftSport = State(initialValue: course.sport)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Course name", text: $draftName)
                        .textInputAutocapitalization(.words)
                }
                Section("Sport") {
                    Picker("Sport", selection: $draftSport) {
                        ForEach(Sport.allCases, id: \.self) { sport in
                            Label(sport.displayName, systemImage: sport.systemImage)
                                .tag(sport)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle("Edit Course")
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
        if !trimmed.isEmpty { course.name = trimmed }
        course.sport = draftSport
        dismiss()
    }
}
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CompassData
import CompassFIT

struct CoursesListView: View {
    @Query(sort: \Course.importDate, order: .reverse)
    private var courses: [Course]

    @State private var isImporting = false
    @Environment(\.modelContext) private var modelContext
    @Environment(CourseImportCoordinator.self) private var importCoordinator

    /// Allowed types for the in-app file picker. Both UTIs are declared in
    /// Info.plist via UTImportedTypeDeclarations; the optional unwrap is
    /// safe at runtime because the declarations are bundled with the app.
    private static let importableTypes: [UTType] = [
        UTType(filenameExtension: "gpx", conformingTo: .xml) ?? .xml,
        UTType(filenameExtension: "fit", conformingTo: .data) ?? .data,
    ]

    var body: some View {
        NavigationStack {
            Group {
                if courses.isEmpty {
                    emptyState
                } else {
                    courseList
                }
            }
            .navigationTitle("Courses")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { isImporting = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .connectionStatusToolbar()
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: Self.importableTypes,
                onCompletion: { result in
                    switch result {
                    case .success(let url):
                        importCoordinator.handle(url: url, context: modelContext)
                    case .failure(let error):
                        importCoordinator.lastError = error.localizedDescription
                    }
                }
            )
        }
    }

    // MARK: - Views

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Courses", systemImage: "map")
        } description: {
            Text("Import a GPX or FIT file to get started.")
        }
    }

    private var courseList: some View {
        List {
            ForEach(courses) { course in
                NavigationLink(destination: CourseDetailView(course: course)) {
                    CourseRowView(course: course)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            }
            .onDelete(perform: deleteCourses)
        }
        .listStyle(.plain)
    }

    // MARK: - Delete

    private func deleteCourses(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(courses[index])
        }
    }

    // File import is handled centrally by `CourseImportCoordinator` so
    // share-sheet "Open in" and the in-app picker share the same parse +
    // duplicate-resolution flow.
}

#Preview {
    CoursesListView()
        .environment(CourseImportCoordinator())
        .modelContainer(for: [Course.self, CourseWaypoint.self, CoursePOI.self], inMemory: true)
}

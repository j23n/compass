import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CompassData
import CompassFIT

struct CoursesListView: View {
    @Query(sort: \Course.importDate, order: .reverse)
    private var courses: [Course]

    @State private var isImporting = false
    @State private var navigationPath: [Course] = []
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
        NavigationStack(path: $navigationPath) {
            Group {
                if courses.isEmpty {
                    emptyState
                } else {
                    courseList
                }
            }
            .navigationTitle("Courses")
            .navigationDestination(for: Course.self) { course in
                CourseDetailView(course: course)
            }
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
        // Auto-push to the just-imported course's detail. Handled both via
        // .onChange (covers imports while the tab is already mounted) and
        // .onAppear (covers a share-sheet import that switches into this
        // tab from cold — .onChange's initial value isn't delivered).
        .onChange(of: importCoordinator.lastImportedCourse) { _, course in
            pushImported(course)
        }
        .onAppear {
            pushImported(importCoordinator.lastImportedCourse)
        }
    }

    private func pushImported(_ course: Course?) {
        guard let course else { return }
        // Replace any existing stack with just the imported course so the
        // user lands directly on its detail view rather than nested under
        // whatever they were previously looking at.
        navigationPath = [course]
        importCoordinator.lastImportedCourse = nil
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
                NavigationLink(value: course) {
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

import SwiftUI
import SwiftData
import CompassData
import CompassFIT

struct CoursesListView: View {
    @Query(sort: \Course.importDate, order: .reverse)
    private var courses: [Course]

    @State private var isImporting = false
    @State private var importError: String?
    @Environment(\.modelContext) private var modelContext

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
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.init(filenameExtension: "gpx", conformingTo: .text)!],
                onCompletion: { result in
                    switch result {
                    case .success(let url):
                        importGPX(from: url)
                    case .failure(let error):
                        importError = error.localizedDescription
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
            Text("Import a GPX file to get started.")
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

    // MARK: - File Import

    private func importGPX(from url: URL) {
        let securityScoped = url.startAccessingSecurityScopedResource()
        defer { if securityScoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            let parsed = try GPXCourseParser.parse(data: data)

            let waypoints = parsed.waypoints.enumerated().map { index, gpxWaypoint in
                CourseWaypoint(
                    order: index,
                    latitude: gpxWaypoint.latitude,
                    longitude: gpxWaypoint.longitude,
                    altitude: gpxWaypoint.altitude,
                    name: gpxWaypoint.name,
                    distanceFromStart: gpxWaypoint.distanceFromStart,
                    timestamp: gpxWaypoint.timestamp
                )
            }

            let pois = parsed.pointsOfInterest.map { poi in
                CoursePOI(
                    latitude: poi.latitude,
                    longitude: poi.longitude,
                    name: poi.name,
                    coursePointType: Int(poi.coursePointType),
                    distanceFromStart: poi.distanceFromStart
                )
            }

            // Use the GPX track's <name> if set, otherwise fall back to the
            // source filename (without extension) so users see a meaningful
            // course name in the list.
            let trimmedName = parsed.name.trimmingCharacters(in: .whitespaces)
            let courseName = trimmedName.isEmpty
                ? url.deletingPathExtension().lastPathComponent
                : trimmedName

            let course = Course(
                name: courseName,
                importDate: Date(),
                sport: .running,
                totalDistance: parsed.totalDistance,
                totalAscent: parsed.totalAscent,
                totalDescent: parsed.totalDescent,
                waypoints: waypoints
            )
            course.pointsOfInterest = pois

            modelContext.insert(course)
            try modelContext.save()
            AppLogger.sync.info("Imported course: \(course.name) with \(course.waypoints.count) waypoints and \(pois.count) POIs")
        } catch {
            importError = error.localizedDescription
            AppLogger.sync.error("GPX import error: \(error)")
        }
    }
}

#Preview {
    CoursesListView()
        .modelContainer(for: [Course.self, CourseWaypoint.self, CoursePOI.self], inMemory: true)
}

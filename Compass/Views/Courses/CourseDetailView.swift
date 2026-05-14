import SwiftUI
import SwiftData
import MapKit
import CompassData
import CompassFIT
import CompassBLE

struct CourseDetailView: View {
    let course: Course
    @Environment(SyncCoordinator.self) private var syncCoordinator
    @Environment(\.modelContext) private var modelContext

    @State private var uploadError: String?
    @State private var isEditing = false
    @State private var editingPOI: CoursePOI?
    @State private var isTurnsExpanded = false

    init(course: Course) {
        self.course = course
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Map
                if !course.waypoints.isEmpty {
                    Text("Route Map")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)

                    MapRouteView(
                        coordinates: course.waypoints
                            .sorted { $0.order < $1.order }
                            .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
                        // Suppress turn cues on the map — the polyline already
                        // shows where the turns are, and the dozens of arrow
                        // glyphs from auto-detected turns drown out actual POIs.
                        // The watch still receives them via the FIT export.
                        pois: course.pointsOfInterest
                            .filter { !CoursePointType(fitCode: UInt8(clamping: $0.coursePointType)).isTurnCue }
                            .map {
                                MapPOI(
                                    coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                                    name: $0.name,
                                    coursePointType: $0.coursePointType
                                )
                            }
                    )
                    .frame(height: 300)
                    .cornerRadius(12)
                    .padding(.horizontal)
                }

                // Stats
                StatsGrid(course: course)
                    .padding(.horizontal)

                // Upload button
                uploadSection
                    .padding(.horizontal)

                // POIs
                if !course.pointsOfInterest.isEmpty {
                    poiSection
                        .padding(.horizontal)
                }

                Spacer()
            }
            .padding(.vertical)
        }
        .navigationTitle(course.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { isEditing = true } label: {
                    Image(systemName: "pencil")
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            CourseEditView(course: course)
        }
        .sheet(item: $editingPOI) { poi in
            POIEditView(poi: poi)
        }
    }

    private var poiSection: some View {
        let sorted = course.pointsOfInterest.sorted { $0.distanceFromStart < $1.distanceFromStart }
        let regular = sorted.filter { !CoursePointType(fitCode: UInt8(clamping: $0.coursePointType)).isTurnCue }
        let turns   = sorted.filter {  CoursePointType(fitCode: UInt8(clamping: $0.coursePointType)).isTurnCue }
        return VStack(alignment: .leading, spacing: 16) {
            if !regular.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Points of Interest")
                        .font(.headline)
                    poiList(regular)
                }
            }
            if !turns.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { isTurnsExpanded.toggle() }
                    } label: {
                        HStack {
                            Text("Turn-by-turn (\(turns.count))")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: isTurnsExpanded ? "chevron.up" : "chevron.down")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if isTurnsExpanded {
                        poiList(turns)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func poiList(_ pois: [CoursePOI]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(pois.enumerated()), id: \.element.persistentModelID) { index, poi in
                Button {
                    editingPOI = poi
                } label: {
                    let type = CoursePointType(fitCode: UInt8(clamping: poi.coursePointType))
                    HStack(spacing: 12) {
                        Image(systemName: type.systemImage)
                            .font(.body)
                            .foregroundStyle(.blue)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(poi.name)
                                .font(.subheadline)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                            Text("\(String(format: "%.2f", poi.distanceFromStart / 1_000)) km · \(type.displayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < pois.count - 1 {
                    Divider().padding(.leading, 48)
                }
            }
        }
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }

    private var uploadSection: some View {
        VStack(spacing: 12) {
            let isConnected = {
                if case .connected = syncCoordinator.connectionState { return true }
                return false
            }()

            // Watch presence indicator (shown when we know the state)
            if course.uploadedToWatch, let date = course.lastUploadDate {
                HStack(spacing: 8) {
                    Image(systemName: "applewatch").foregroundStyle(.secondary)
                    Text("Last uploaded \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }

            Button(action: performUpload) {
                HStack {
                    Image(systemName: "arrow.up.doc.fill")
                    Text(course.uploadedToWatch ? "Re-upload to Watch" : "Upload to Watch")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(isConnected ? Color.blue : Color.gray)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .disabled(!isConnected)

            if !isConnected {
                Text("Connect to your watch to upload courses")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            if let error = uploadError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            if case .syncing = syncCoordinator.state {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Uploading...")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else if case .completed = syncCoordinator.state {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("Uploaded successfully")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func performUpload() {
        uploadError = nil

        let fitWaypoints = course.waypoints.sorted { $0.order < $1.order }.map { waypoint in
            FITCourseWaypoint(
                latitude: waypoint.latitude,
                longitude: waypoint.longitude,
                altitude: waypoint.altitude,
                name: waypoint.name,
                distanceFromStart: waypoint.distanceFromStart,
                timestamp: waypoint.timestamp
            )
        }

        let fitPOIs = course.pointsOfInterest.map { poi in
            FITCourseWaypoint(
                latitude: poi.latitude,
                longitude: poi.longitude,
                altitude: nil,
                name: poi.name,
                distanceFromStart: poi.distanceFromStart,
                coursePointType: UInt8(clamping: poi.coursePointType)
            )
        }

        let fitData = CourseFITEncoder.encode(
            name: course.name,
            sport: course.sport.fitSportCode,
            waypoints: fitWaypoints,
            pointsOfInterest: fitPOIs,
            totalDistance: course.totalDistance,
            totalAscent: course.totalAscent,
            totalDescent: course.totalDescent,
            estimatedDuration: course.estimatedDuration
        )

        let safeName = sanitizeFilename(course.name)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName).fit")

        do {
            try fitData.write(to: tempURL)
            syncCoordinator.uploadCourse(fitURL: tempURL, fitSize: fitData.count, course: course)
        } catch {
            uploadError = error.localizedDescription
        }
    }

    /// Build a filesystem-safe filename: keep alphanumerics, collapse runs of
    /// other chars into a single underscore, trim leading/trailing underscores,
    /// fall back to "course" if the result is empty.
    private func sanitizeFilename(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        var out = ""
        var lastWasUnderscore = false
        for ch in raw {
            if allowed.contains(ch) {
                out.append(ch)
                lastWasUnderscore = false
            } else if !lastWasUnderscore {
                out.append("_")
                lastWasUnderscore = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let capped = String(trimmed.prefix(40))
        return capped.isEmpty ? "course" : capped
    }
}

// MARK: - Stats Grid

struct StatsGrid: View {
    let course: Course

    var body: some View {
        VStack(spacing: 12) {
            Text("Stats")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible()), count: 3),
                spacing: 10
            ) {
                StatCell(
                    title: "Distance",
                    value: String(format: "%.1f", course.totalDistance / 1000),
                    unit: "km"
                )
                StatCell(
                    title: "Est. Time",
                    value: formattedDuration(course.estimatedDuration)
                )
                if let ascent = course.totalAscent {
                    StatCell(
                        title: "Ascent",
                        value: "+\(String(format: "%.0f", ascent))",
                        unit: "m"
                    )
                }
                if let descent = course.totalDescent {
                    StatCell(
                        title: "Descent",
                        value: "-\(String(format: "%.0f", descent))",
                        unit: "m"
                    )
                }
                StatCell(
                    title: "Waypoints",
                    value: "\(course.waypoints.count)"
                )
            }
        }
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

#Preview {
    let course = Course(
        name: "Sample Loop",
        importDate: Date(),
        sport: .running,
        totalDistance: 8500,
        totalAscent: 120
    )

    let container = try! ModelContainer(
        for: Course.self, CourseWaypoint.self, CoursePOI.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    CourseDetailView(course: course)
        .environment(SyncCoordinator(deviceManager: MockGarminDevice(), modelContainer: container))
        .modelContainer(container)
}

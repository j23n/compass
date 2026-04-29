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

    @State private var selectedSport: Sport
    @State private var uploadError: String?
    @State private var isRenaming = false
    @State private var draftName = ""

    init(course: Course) {
        self.course = course
        self._selectedSport = State(initialValue: course.sport)
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

                    MapRouteView(coordinates: course.waypoints
                        .sorted { $0.order < $1.order }
                        .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    )
                    .frame(height: 300)
                    .cornerRadius(12)
                    .padding(.horizontal)
                }

                // Stats
                StatsGrid(course: course)
                    .padding(.horizontal)

                // Sport picker
                sportSection
                    .padding(.horizontal)

                // Upload button
                uploadSection
                    .padding(.horizontal)

                Spacer()
            }
            .padding(.vertical)
        }
        .navigationTitle(course.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    draftName = course.name
                    isRenaming = true
                } label: {
                    Image(systemName: "pencil")
                }
            }
        }
        .alert("Rename Course", isPresented: $isRenaming) {
            TextField("Name", text: $draftName)
            Button("Save") {
                let trimmed = draftName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { course.name = trimmed }
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    private var sportSection: some View {
        HStack {
            Text("Sport")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Picker("Sport", selection: $selectedSport) {
                ForEach(Sport.allCases, id: \.self) { sport in
                    Label(sport.displayName, systemImage: sport.systemImage)
                        .tag(sport)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: selectedSport) { _, new in
                course.sport = new
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }

    private var uploadSection: some View {
        VStack(spacing: 12) {
            let isConnected = {
                if case .connected = syncCoordinator.connectionState {
                    return true
                }
                return false
            }()

            Button(action: performUpload) {
                HStack {
                    Image(systemName: "arrow.up.doc.fill")
                    Text("Upload to Watch")
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

            // Status indicator
            if case .syncing = syncCoordinator.state {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Uploading...")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else if case .completed = syncCoordinator.state {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Uploaded")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func performUpload() {
        uploadError = nil

        // Convert CourseWaypoint to FITCourseWaypoint
        let fitWaypoints = course.waypoints.sorted { $0.order < $1.order }.map { waypoint in
            FITCourseWaypoint(
                latitude: waypoint.latitude,
                longitude: waypoint.longitude,
                altitude: waypoint.altitude,
                name: waypoint.name,
                distanceFromStart: waypoint.distanceFromStart
            )
        }

        // Encode course to FIT
        let fitData = CourseFITEncoder.encode(
            name: course.name,
            waypoints: fitWaypoints,
            totalDistance: course.totalDistance
        )

        // Write to temp file
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(course.name.replacingOccurrences(of: " ", with: "_")).fit"
        )

        do {
            try fitData.write(to: tempURL)
            syncCoordinator.uploadCourse(fitURL: tempURL)
        } catch {
            uploadError = error.localizedDescription
        }
    }
}

// MARK: - Stats Grid

struct StatsGrid: View {
    let course: Course

    var body: some View {
        VStack(spacing: 12) {
            Text("Course Stats")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 12
            ) {
                StatCell(
                    title: "Distance",
                    value: String(format: "%.1f", course.totalDistance / 1000),
                    unit: "km"
                )
                if let ascent = course.totalAscent {
                    StatCell(
                        title: "Ascent",
                        value: String(format: "%.0f", ascent),
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
}

#Preview {
    let course = Course(
        name: "Sample Loop",
        importDate: Date(),
        sport: .running,
        totalDistance: 8500,
        totalAscent: 120
    )

    CourseDetailView(course: course)
        .environment(SyncCoordinator(deviceManager: MockGarminDevice()))
        .modelContainer(for: [Course.self, CourseWaypoint.self], inMemory: true)
}

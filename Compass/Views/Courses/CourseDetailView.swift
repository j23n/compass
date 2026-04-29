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
    @State private var watchPresence: Bool? = nil  // nil=unknown, true=on watch, false=not found

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
        .task {
            watchPresence = await syncCoordinator.checkCourseOnWatch(course: course)
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
                if case .connected = syncCoordinator.connectionState { return true }
                return false
            }()

            // Watch presence indicator (shown when we know the state)
            if course.uploadedToWatch {
                watchStatusRow(isConnected: isConnected)
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
                .onAppear {
                    watchPresence = true
                }
            }
        }
    }

    @ViewBuilder
    private func watchStatusRow(isConnected: Bool) -> some View {
        HStack(spacing: 8) {
            switch watchPresence {
            case .none:
                if isConnected {
                    ProgressView().scaleEffect(0.7)
                    Text("Checking watch…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "applewatch").foregroundStyle(.secondary)
                    if let date = course.lastUploadDate {
                        Text("Last uploaded \(date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            case .some(true):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("On your watch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .some(false):
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text("Not found on watch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func performUpload() {
        uploadError = nil

        let fitWaypoints = course.waypoints.sorted { $0.order < $1.order }.map { waypoint in
            FITCourseWaypoint(
                latitude: waypoint.latitude,
                longitude: waypoint.longitude,
                altitude: waypoint.altitude,
                name: waypoint.name,
                distanceFromStart: waypoint.distanceFromStart
            )
        }

        let fitData = CourseFITEncoder.encode(
            name: course.name,
            sport: course.sport.fitSportCode,
            waypoints: fitWaypoints,
            totalDistance: course.totalDistance
        )

        let safeName = sanitizeFilename(course.name)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName).fit")

        do {
            try fitData.write(to: tempURL)
            watchPresence = nil
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
                StatCell(
                    title: "Est. Time",
                    value: formattedDuration(course.estimatedDuration)
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

    CourseDetailView(course: course)
        .environment(SyncCoordinator(deviceManager: MockGarminDevice()))
        .modelContainer(for: [Course.self, CourseWaypoint.self], inMemory: true)
}

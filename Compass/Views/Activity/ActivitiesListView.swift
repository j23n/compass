import SwiftUI
import SwiftData
import CompassData


/// The Activities tab — full reverse-chronological list with sport filter chips.
struct ActivitiesListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Activity.startDate, order: .reverse)
    private var allActivities: [Activity]

    @State private var selectedSport: Sport?

    private var availableSports: [Sport] {
        let seen = Set(allActivities.map(\.sport))
        return Sport.allCases.filter { seen.contains($0) }
    }

    private var filteredActivities: [Activity] {
        guard let sport = selectedSport else { return allActivities }
        return allActivities.filter { $0.sport == sport }
    }

    var body: some View {
        NavigationStack {
            Group {
                if allActivities.isEmpty {
                    emptyState
                } else {
                    activityList
                }
            }
            .navigationTitle("Activities")
            .connectionStatusToolbar()
        }
    }

    // MARK: - List

    private var activityList: some View {
        List {
            Section {
                filterChipsRow
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if filteredActivities.isEmpty {
                Section {
                    Text("No \(selectedSport?.displayName ?? "") activities yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 32)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                Section {
                    ForEach(filteredActivities) { activity in
                        NavigationLink(destination: ActivityDetailView(activity: activity)) {
                            ActivityRowView(activity: activity)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    }
                    .onDelete(perform: deleteActivities)
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Filter chips

    private var filterChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(label: "All", systemImage: "square.grid.2x2", isSelected: selectedSport == nil) {
                    selectedSport = nil
                }
                ForEach(availableSports, id: \.self) { sport in
                    filterChip(
                        label: sport.displayName,
                        systemImage: sport.systemImage,
                        isSelected: selectedSport == sport
                    ) {
                        selectedSport = selectedSport == sport ? nil : sport
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func filterChip(
        label: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.caption)
                Text(label)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? Color.accentColor : Color(.systemGray5))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Delete

    private func deleteActivities(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(filteredActivities[index])
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Activities", systemImage: "figure.run")
        } description: {
            Text("Activities synced from your watch will appear here.")
        }
    }
}

#Preview {
    ActivitiesListView()
        .modelContainer(for: [Activity.self, TrackPoint.self], inMemory: true)
}

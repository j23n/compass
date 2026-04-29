import SwiftUI

struct CourseFilesView: View {
    @State private var files: [CourseFileStore.StoredFile] = []
    @State private var showShareSheet = false
    @State private var shareItems: [URL] = []

    private let fileStore = CourseFileStore.shared

    var body: some View {
        NavigationStack {
            contentBody
                .navigationTitle("Course Files")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !files.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                shareItems = files.map { $0.url }
                                showShareSheet = true
                            } label: {
                                Label("Export All", systemImage: "arrow.up.doc")
                            }
                        }
                    }
                }
                .sheet(isPresented: $showShareSheet) {
                    ActivityView(items: shareItems)
                }
                .onAppear {
                    refreshFiles()
                }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        if files.isEmpty {
            ContentUnavailableView {
                Label("No Files", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            } description: {
                Text("FIT course files uploaded to the watch will appear here.")
            }
        } else {
            filesList
        }
    }

    @ViewBuilder
    private var filesList: some View {
        List(files, id: \.id) { file in
            fileListRow(for: file)
        }
        .listStyle(.plain)
    }

    private func fileListRow(for file: CourseFileStore.StoredFile) -> some View {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short

        return HStack(spacing: 12) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.title3)
                .foregroundStyle(.green)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(file.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 12) {
                    Text(formatFileSize(file.size))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(dateFormatter.string(from: file.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            ShareLink(item: file.url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .tint(.blue)

            Button(role: .destructive) {
                deleteFile(file)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func refreshFiles() {
        files = fileStore.allFiles()
    }

    private func deleteFile(_ file: CourseFileStore.StoredFile) {
        try? fileStore.delete(file)
        refreshFiles()
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB, .useBytes]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

#Preview {
    CourseFilesView()
}

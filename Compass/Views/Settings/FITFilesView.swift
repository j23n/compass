import SwiftUI

struct FITFilesView: View {
    @State private var files: [FITFileStore.StoredFile] = []
    @State private var showShareSheet = false
    @State private var shareItems: [URL] = []

    private let fileStore = FITFileStore.shared

    var body: some View {
        NavigationStack {
            contentBody
                .navigationTitle("FIT Files")
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
                Label("No Files", systemImage: "doc.badge.arrow.up")
            } description: {
                Text("FIT files from syncs will appear here.")
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

    private func fileListRow(for file: FITFileStore.StoredFile) -> some View {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short

        return HStack(spacing: 12) {
            Image(systemName: file.type.systemImage)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(file.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 12) {
                    Text(file.type.displayName)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(4)

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

    private func deleteFile(_ file: FITFileStore.StoredFile) {
        try? fileStore.delete(file)
        refreshFiles()
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

#Preview {
    FITFilesView()
}

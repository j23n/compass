import SwiftUI

struct FITFilesView: View {
    @Environment(SyncCoordinator.self) private var syncCoordinator
    @State private var files: [FITFileStore.StoredFile] = []
    @State private var showShareSheet = false
    @State private var shareItems: [URL] = []
    @State private var selectedFiles: Set<UUID> = []
    @State private var isSelectionMode = false

    private let fileStore = FITFileStore.shared

    private var allSelected: Bool {
        !files.isEmpty && selectedFiles.count == files.count
    }

    var body: some View {
        NavigationStack {
            contentBody
                .navigationTitle("FIT Files")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !files.isEmpty {
                        if isSelectionMode {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Cancel") {
                                    isSelectionMode = false
                                    selectedFiles.removeAll()
                                }
                            }
                            ToolbarItemGroup(placement: .topBarTrailing) {
                                Button(allSelected ? "Deselect All" : "Select All") {
                                    if allSelected {
                                        selectedFiles.removeAll()
                                    } else {
                                        selectedFiles = Set(files.map(\.id))
                                    }
                                }
                                Button("Share") {
                                    shareSelectedFiles()
                                }
                                .disabled(selectedFiles.isEmpty)
                            }
                        } else {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {
                                    isSelectionMode = true
                                } label: {
                                    Label("Select", systemImage: "checklist")
                                }
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
                .contentShape(Rectangle())
                .onTapGesture {
                    if isSelectionMode {
                        if selectedFiles.contains(file.id) {
                            selectedFiles.remove(file.id)
                        } else {
                            selectedFiles.insert(file.id)
                        }
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !isSelectionMode {
                        ShareLink(item: file.url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .tint(.blue)

                        Button {
                            Task { await syncCoordinator.archiveFITFile(named: file.name) }
                        } label: {
                            Label("Mark Synced", systemImage: "checkmark.circle")
                        }
                        .tint(.green)

                        Button(role: .destructive) {
                            deleteFile(file)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
        }
        .listStyle(.plain)
    }

    private func fileListRow(for file: FITFileStore.StoredFile) -> some View {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short

        return HStack(spacing: 12) {
            if isSelectionMode {
                Image(systemName: selectedFiles.contains(file.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedFiles.contains(file.id) ? .blue : .secondary)
                    .font(.title3)
            }
            
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
    }

    private func shareSelectedFiles() {
        let selectedUrls = files.filter { selectedFiles.contains($0.id) }.map { $0.url }
        if selectedUrls.isEmpty { return }

        FileArchive.shareMultipleFiles(selectedUrls, archiveName: "fit-files") { urlsToShare in
            shareItems = urlsToShare
            showShareSheet = true
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
